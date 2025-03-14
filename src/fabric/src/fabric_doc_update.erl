% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(fabric_doc_update).

-export([go/3]).

-include_lib("mem3/include/mem3.hrl").
-include_lib("couch/include/couch_db.hrl").

-record(acc, {
    waiting_count,
    doc_count,
    w,
    grouped_docs,
    reply
}).

go(_, [], _) ->
    {ok, []};
go(DbName, AllDocs0, Opts) ->
    AllDocs1 = before_doc_update(DbName, AllDocs0, Opts),
    AllDocs = tag_docs(AllDocs1),
    validate_atomic_update(DbName, AllDocs, lists:member(all_or_nothing, Opts)),
    Options = lists:delete(all_or_nothing, Opts),
    GroupedDocs = lists:map(
        fun({#shard{name = Name, node = Node} = Shard, Docs}) ->
            Docs1 = untag_docs(Docs),
            Ref = rexi:cast(Node, {fabric_rpc, update_docs, [Name, Docs1, Options]}),
            {Shard#shard{ref = Ref}, Docs}
        end,
        group_docs_by_shard(DbName, AllDocs)
    ),
    {Workers, _} = lists:unzip(GroupedDocs),
    RexiMon = fabric_util:create_monitors(Workers),
    W = couch_util:get_value(w, Options, integer_to_list(mem3:quorum(DbName))),
    Acc0 = #acc{
        waiting_count = length(Workers),
        doc_count = length(AllDocs),
        w = list_to_integer(W),
        grouped_docs = GroupedDocs,
        reply = dict:new()
    },
    Timeout = fabric_util:request_timeout(),
    try rexi_utils:recv(Workers, #shard.ref, fun handle_message/3, Acc0, infinity, Timeout) of
        {ok, {Health, Results}} when
            Health =:= ok; Health =:= accepted; Health =:= error
        ->
            ensure_all_responses(Health, AllDocs, Results);
        {timeout, Acc} ->
            #acc{w = W1, grouped_docs = GroupedDocs1, reply = DocReplDict} = Acc,
            {DefunctWorkers, _} = lists:unzip(GroupedDocs1),
            fabric_util:log_timeout(DefunctWorkers, "update_docs"),
            {Health, _, Resp} = dict:fold(
                fun force_reply/3,
                {ok, W1, []},
                DocReplDict
            ),
            ensure_all_responses(Health, AllDocs, Resp);
        Else ->
            Else
    after
        rexi_monitor:stop(RexiMon)
    end.

handle_message({rexi_DOWN, _, {_, NodeRef}, _}, _Worker, #acc{} = Acc0) ->
    #acc{grouped_docs = GroupedDocs} = Acc0,
    NewGrpDocs = [X || {#shard{node = N}, _} = X <- GroupedDocs, N =/= NodeRef],
    skip_message(Acc0#acc{waiting_count = length(NewGrpDocs), grouped_docs = NewGrpDocs});
handle_message({rexi_EXIT, _}, Worker, #acc{} = Acc0) ->
    #acc{waiting_count = WC, grouped_docs = GrpDocs} = Acc0,
    NewGrpDocs = lists:keydelete(Worker, 1, GrpDocs),
    skip_message(Acc0#acc{waiting_count = WC - 1, grouped_docs = NewGrpDocs});
handle_message({error, all_dbs_active}, Worker, #acc{} = Acc0) ->
    % treat it like rexi_EXIT, the hope at least one copy will return successfully
    #acc{waiting_count = WC, grouped_docs = GrpDocs} = Acc0,
    NewGrpDocs = lists:keydelete(Worker, 1, GrpDocs),
    skip_message(Acc0#acc{waiting_count = WC - 1, grouped_docs = NewGrpDocs});
handle_message(internal_server_error, Worker, #acc{} = Acc0) ->
    % happens when we fail to load validation functions in an RPC worker
    #acc{waiting_count = WC, grouped_docs = GrpDocs} = Acc0,
    NewGrpDocs = lists:keydelete(Worker, 1, GrpDocs),
    skip_message(Acc0#acc{waiting_count = WC - 1, grouped_docs = NewGrpDocs});
handle_message(attachment_chunk_received, _Worker, #acc{} = Acc0) ->
    {ok, Acc0};
handle_message({ok, Replies}, Worker, #acc{} = Acc0) ->
    #acc{
        waiting_count = WaitingCount,
        doc_count = DocCount,
        w = W,
        grouped_docs = GroupedDocs,
        reply = DocReplyDict0
    } = Acc0,
    {value, {_, Docs}, NewGrpDocs} = lists:keytake(Worker, 1, GroupedDocs),
    DocReplyDict = append_update_replies(Docs, Replies, DocReplyDict0),
    case {WaitingCount, dict:size(DocReplyDict)} of
        {1, _} ->
            % last message has arrived, we need to conclude things
            {Health, W, Reply} = dict:fold(
                fun force_reply/3,
                {ok, W, []},
                DocReplyDict
            ),
            {stop, {Health, Reply}};
        {_, DocCount} ->
            % we've got at least one reply for each document, let's take a look
            case dict:fold(fun maybe_reply/3, {stop, W, []}, DocReplyDict) of
                continue ->
                    {ok, Acc0#acc{
                        waiting_count = WaitingCount - 1,
                        grouped_docs = NewGrpDocs,
                        reply = DocReplyDict
                    }};
                {stop, W, FinalReplies} ->
                    {stop, {ok, FinalReplies}}
            end;
        _ ->
            {ok, Acc0#acc{
                waiting_count = WaitingCount - 1, grouped_docs = NewGrpDocs, reply = DocReplyDict
            }}
    end;
handle_message({missing_stub, Stub}, _, _) ->
    throw({missing_stub, Stub});
handle_message({not_found, no_db_file} = X, Worker, #acc{} = Acc0) ->
    #acc{grouped_docs = GroupedDocs} = Acc0,
    Docs = couch_util:get_value(Worker, GroupedDocs),
    handle_message({ok, [X || _D <- Docs]}, Worker, Acc0);
handle_message({bad_request, Msg}, _, _) ->
    throw({bad_request, Msg});
handle_message({forbidden, Msg}, _, _) ->
    throw({forbidden, Msg});
handle_message({request_entity_too_large, Entity}, _, _) ->
    throw({request_entity_too_large, Entity}).

before_doc_update(DbName, Docs, Opts) ->
    % Use the same pattern as in couch_db:validate_doc_update/3. If the document was already
    % checked during the interactive edit we don't want to spend time in the internal replicator
    % revalidating everything.
    UpdateType =
        case get(io_priority) of
            {internal_repl, _} ->
                ?REPLICATED_CHANGES;
            _ ->
                ?INTERACTIVE_EDIT
        end,
    case {fabric_util:is_replicator_db(DbName), fabric_util:is_users_db(DbName)} of
        {true, _} ->
            %% cluster db is expensive to create so we only do it if we have to
            Db = fabric_util:open_cluster_db(DbName, Opts),
            [
                couch_replicator_docs:before_doc_update(Doc, Db, UpdateType)
             || Doc <- Docs
            ];
        {_, true} ->
            %% cluster db is expensive to create so we only do it if we have to
            Db = fabric_util:open_cluster_db(DbName, Opts),
            [
                couch_users_db:before_doc_update(Doc, Db, UpdateType)
             || Doc <- Docs
            ];
        _ ->
            Docs
    end.

tag_docs([]) ->
    [];
tag_docs([#doc{meta = Meta} = Doc | Rest]) ->
    [Doc#doc{meta = [{ref, make_ref()} | Meta]} | tag_docs(Rest)].

untag_docs([]) ->
    [];
untag_docs([#doc{meta = Meta} = Doc | Rest]) ->
    [Doc#doc{meta = lists:keydelete(ref, 1, Meta)} | untag_docs(Rest)].

force_reply(Doc, [], {_, W, Acc}) ->
    {error, W, [{Doc, {error, internal_server_error}} | Acc]};
force_reply(Doc, [FirstReply | _] = Replies, {Health, W, Acc}) ->
    case update_quorum_met(W, Replies) of
        {true, Reply} ->
            % corner case new_edits:false and vdu: [noreply, forbidden, noreply]
            case check_forbidden_msg(Replies) of
                {forbidden, ForbiddenReply} ->
                    {Health, W, [{Doc, ForbiddenReply} | Acc]};
                false ->
                    {Health, W, [{Doc, Reply} | Acc]}
            end;
        false ->
            case [Reply || {ok, Reply} <- Replies] of
                [] ->
                    % check if all errors are identical, if so inherit health
                    case lists:all(fun(E) -> E =:= FirstReply end, Replies) of
                        true ->
                            CounterKey = [fabric, doc_update, errors],
                            couch_stats:increment_counter(CounterKey),
                            {Health, W, [{Doc, FirstReply} | Acc]};
                        false ->
                            CounterKey = [fabric, doc_update, mismatched_errors],
                            couch_stats:increment_counter(CounterKey),
                            case check_forbidden_msg(Replies) of
                                {forbidden, ForbiddenReply} ->
                                    {Health, W, [{Doc, ForbiddenReply} | Acc]};
                                false ->
                                    {error, W, [{Doc, FirstReply} | Acc]}
                            end
                    end;
                [AcceptedRev | _] ->
                    CounterKey = [fabric, doc_update, write_quorum_errors],
                    couch_stats:increment_counter(CounterKey),
                    NewHealth =
                        case Health of
                            ok -> accepted;
                            _ -> Health
                        end,
                    {NewHealth, W, [{Doc, {accepted, AcceptedRev}} | Acc]}
            end
    end.

maybe_reply(_, _, continue) ->
    % we didn't meet quorum for all docs, so we're fast-forwarding the fold
    continue;
maybe_reply(Doc, Replies, {stop, W, Acc}) ->
    case update_quorum_met(W, Replies) of
        {true, Reply} ->
            {stop, W, [{Doc, Reply} | Acc]};
        false ->
            continue
    end.

% this ensures that we got some response for all documents being updated
ensure_all_responses(Health, AllDocs, Resp) ->
    Results = [
        R
     || R <- couch_util:reorder_results(
            AllDocs,
            Resp,
            {error, internal_server_error}
        ),
        R =/= noreply
    ],
    case lists:member({error, internal_server_error}, Results) of
        true ->
            {error, Results};
        false ->
            {Health, Results}
    end.

% This is a corner case where
% 1) revision tree for the document are out of sync across nodes
% 2) update on one node extends the revision tree
% 3) VDU forbids the document
% 4) remaining nodes do not extend revision tree, so noreply is returned
% If at at least one node forbids the update, and all other replies
% are noreply, then we reject the update
check_forbidden_msg(Replies) ->
    Pred = fun
        ({_, {forbidden, _}}) ->
            true;
        (_) ->
            false
    end,
    case lists:partition(Pred, Replies) of
        {[], _} ->
            false;
        {[ForbiddenReply = {_, {forbidden, _}} | _], RemReplies} ->
            case lists:all(fun(E) -> E =:= noreply end, RemReplies) of
                true ->
                    {forbidden, ForbiddenReply};
                false ->
                    false
            end
    end.

update_quorum_met(W, Replies) ->
    Counters = lists:foldl(
        fun(R, D) -> orddict:update_counter(R, 1, D) end,
        orddict:new(),
        Replies
    ),
    GoodReplies = lists:filter(fun good_reply/1, Counters),
    case lists:dropwhile(fun({_, Count}) -> Count < W end, GoodReplies) of
        [] ->
            false;
        [{FinalReply, _} | _] ->
            {true, FinalReply}
    end.

good_reply({{ok, _}, _}) ->
    true;
good_reply({noreply, _}) ->
    true;
good_reply(_) ->
    false.

-spec group_docs_by_shard(binary(), [#doc{}]) -> [{#shard{}, [#doc{}]}].
group_docs_by_shard(DbName, Docs) ->
    dict:to_list(
        lists:foldl(
            fun(#doc{id = Id} = Doc, D0) ->
                lists:foldl(
                    fun(Shard, D1) ->
                        dict:append(Shard, Doc, D1)
                    end,
                    D0,
                    mem3:shards(DbName, Id)
                )
            end,
            dict:new(),
            Docs
        )
    ).

append_update_replies([], [], DocReplyDict) ->
    DocReplyDict;
append_update_replies([Doc | Rest], [], Dict0) ->
    % icky, if replicated_changes only errors show up in result
    append_update_replies(Rest, [], dict:append(Doc, noreply, Dict0));
append_update_replies([Doc | Rest1], [Reply | Rest2], Dict0) ->
    append_update_replies(Rest1, Rest2, dict:append(Doc, Reply, Dict0)).

skip_message(#acc{waiting_count = 0, w = W, reply = DocReplyDict}) ->
    {Health, W, Reply} = dict:fold(fun force_reply/3, {ok, W, []}, DocReplyDict),
    {stop, {Health, Reply}};
skip_message(#acc{} = Acc0) ->
    {ok, Acc0}.

validate_atomic_update(_, _, false) ->
    ok;
validate_atomic_update(_DbName, AllDocs, true) ->
    % TODO actually perform the validation.  This requires some hackery, we need
    % to basically extract the prep_and_validate_updates function from couch_db
    % and only run that, without actually writing in case of a success.
    Error = {not_implemented, <<"all_or_nothing is not supported">>},
    PreCommitFailures = lists:map(
        fun(#doc{id = Id, revs = {Pos, Revs}}) ->
            case Revs of
                [] -> RevId = <<>>;
                [RevId | _] -> ok
            end,
            {{Id, {Pos, RevId}}, Error}
        end,
        AllDocs
    ),
    throw({aborted, PreCommitFailures}).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

setup_all() ->
    meck:new([couch_log, couch_stats]),
    meck:expect(couch_log, warning, fun(_, _) -> ok end),
    meck:expect(couch_stats, increment_counter, fun(_) -> ok end).

teardown_all(_) ->
    meck:unload().

doc_update_test_() ->
    {
        setup,
        fun setup_all/0,
        fun teardown_all/1,
        [
            fun doc_update1/0,
            fun doc_update2/0,
            fun doc_update3/0,
            fun handle_all_dbs_active/0,
            fun handle_two_all_dbs_actives/0,
            fun one_forbid/0,
            fun two_forbid/0,
            fun extend_tree_forbid/0,
            fun other_errors_one_forbid/0,
            fun one_error_two_forbid/0,
            fun one_success_two_forbid/0,
            fun worker_before_doc_update_forbidden/0
        ]
    }.

% eunits
doc_update1() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1],
    Docs2 = [Doc1, Doc2],
    Dict = dict:from_list([{Doc, []} || Doc <- Docs]),
    Dict2 = dict:from_list([{Doc, []} || Doc <- Docs2]),

    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),

    % test for W = 2
    AccW2 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = Dict
    },

    {ok, #acc{waiting_count = WaitingCountW2_1} = AccW2_1} =
        handle_message({ok, [{ok, Doc1}]}, hd(Shards), AccW2),
    ?assertEqual(WaitingCountW2_1, 2),
    {stop, FinalReplyW2} =
        handle_message({ok, [{ok, Doc1}]}, lists:nth(2, Shards), AccW2_1),
    ?assertEqual({ok, [{Doc1, {ok, Doc1}}]}, FinalReplyW2),

    % test for W = 3
    AccW3 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 3,
        grouped_docs = GroupedDocs,
        reply = Dict
    },

    {ok, #acc{waiting_count = WaitingCountW3_1} = AccW3_1} =
        handle_message({ok, [{ok, Doc1}]}, hd(Shards), AccW3),
    ?assertEqual(WaitingCountW3_1, 2),

    {ok, #acc{waiting_count = WaitingCountW3_2} = AccW3_2} =
        handle_message({ok, [{ok, Doc1}]}, lists:nth(2, Shards), AccW3_1),
    ?assertEqual(WaitingCountW3_2, 1),

    {stop, FinalReplyW3} =
        handle_message({ok, [{ok, Doc1}]}, lists:nth(3, Shards), AccW3_2),
    ?assertEqual({ok, [{Doc1, {ok, Doc1}}]}, FinalReplyW3),

    % test w quorum > # shards, which should fail immediately

    Shards2 = mem3_util:create_partition_map("foo", 1, 1, ["node1"]),
    GroupedDocs2 = group_docs_by_shard_hack(<<"foo">>, Shards2, Docs),

    AccW4 =
        #acc{
            waiting_count = length(Shards2),
            doc_count = length(Docs),
            w = 2,
            grouped_docs = GroupedDocs2,
            reply = Dict
        },
    Bool =
        case handle_message({ok, [{ok, Doc1}]}, hd(Shards2), AccW4) of
            {stop, _Reply} ->
                true;
            _ ->
                false
        end,
    ?assertEqual(Bool, true),

    % Docs with no replies should end up as {error, internal_server_error}
    SA1 = #shard{node = a, range = 1},
    SB1 = #shard{node = b, range = 1},
    SA2 = #shard{node = a, range = 2},
    SB2 = #shard{node = b, range = 2},
    GroupedDocs3 = [{SA1, [Doc1]}, {SB1, [Doc1]}, {SA2, [Doc2]}, {SB2, [Doc2]}],
    StW5_0 = #acc{
        waiting_count = length(GroupedDocs3),
        doc_count = length(Docs2),
        w = 2,
        grouped_docs = GroupedDocs3,
        reply = Dict2
    },
    {ok, StW5_1} = handle_message({ok, [{ok, "A"}]}, SA1, StW5_0),
    {ok, StW5_2} = handle_message({rexi_EXIT, nil}, SB1, StW5_1),
    {ok, StW5_3} = handle_message({rexi_EXIT, nil}, SA2, StW5_2),
    {stop, ReplyW5} = handle_message({rexi_EXIT, nil}, SB2, StW5_3),
    ?assertEqual(
        {error, [{Doc1, {accepted, "A"}}, {Doc2, {error, internal_server_error}}]},
        ReplyW5
    ).

doc_update2() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),
    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message({ok, [{ok, Doc1}, {ok, Doc2}]}, hd(Shards), Acc0),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message({rexi_EXIT, 1}, lists:nth(2, Shards), Acc1),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message({rexi_EXIT, 1}, lists:nth(3, Shards), Acc2),

    ?assertEqual(
        {accepted, [{Doc1, {accepted, Doc1}}, {Doc2, {accepted, Doc2}}]},
        Reply
    ).

doc_update3() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),
    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message({ok, [{ok, Doc1}, {ok, Doc2}]}, hd(Shards), Acc0),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message({rexi_EXIT, 1}, lists:nth(2, Shards), Acc1),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message({ok, [{ok, Doc1}, {ok, Doc2}]}, lists:nth(3, Shards), Acc2),

    ?assertEqual({ok, [{Doc1, {ok, Doc1}}, {Doc2, {ok, Doc2}}]}, Reply).

handle_all_dbs_active() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),
    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message({ok, [{ok, Doc1}, {ok, Doc2}]}, hd(Shards), Acc0),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message({error, all_dbs_active}, lists:nth(2, Shards), Acc1),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message({ok, [{ok, Doc1}, {ok, Doc2}]}, lists:nth(3, Shards), Acc2),

    ?assertEqual({ok, [{Doc1, {ok, Doc1}}, {Doc2, {ok, Doc2}}]}, Reply).

handle_two_all_dbs_actives() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),
    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message({ok, [{ok, Doc1}, {ok, Doc2}]}, hd(Shards), Acc0),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message({error, all_dbs_active}, lists:nth(2, Shards), Acc1),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message({error, all_dbs_active}, lists:nth(3, Shards), Acc2),

    ?assertEqual(
        {accepted, [{Doc1, {accepted, Doc1}}, {Doc2, {accepted, Doc2}}]},
        Reply
    ).

one_forbid() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),

    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message({ok, [{ok, Doc1}, noreply]}, hd(Shards), Acc0),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, lists:nth(2, Shards), Acc1
        ),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message({ok, [{ok, Doc1}, noreply]}, lists:nth(3, Shards), Acc2),

    ?assertEqual(
        {ok, [
            {Doc1, {ok, Doc1}},
            {Doc2, {Doc2, {forbidden, <<"not allowed">>}}}
        ]},
        Reply
    ).

two_forbid() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),

    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message({ok, [{ok, Doc1}, noreply]}, hd(Shards), Acc0),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, lists:nth(2, Shards), Acc1
        ),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, lists:nth(3, Shards), Acc2
        ),

    ?assertEqual(
        {ok, [
            {Doc1, {ok, Doc1}},
            {Doc2, {Doc2, {forbidden, <<"not allowed">>}}}
        ]},
        Reply
    ).

% This should actually never happen, because an `{ok, Doc}` message means that the revision
% tree is extended and so the VDU should forbid the document.
% Leaving this test here to make sure quorum rules still apply.
extend_tree_forbid() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),

    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message({ok, [{ok, Doc1}, {ok, Doc2}]}, hd(Shards), Acc0),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, lists:nth(2, Shards), Acc1
        ),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message({ok, [{ok, Doc1}, {ok, Doc2}]}, lists:nth(3, Shards), Acc2),

    ?assertEqual({ok, [{Doc1, {ok, Doc1}}, {Doc2, {ok, Doc2}}]}, Reply).

other_errors_one_forbid() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),

    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message({ok, [{ok, Doc1}, {Doc2, {error, <<"foo">>}}]}, hd(Shards), Acc0),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message({ok, [{ok, Doc1}, {Doc2, {error, <<"bar">>}}]}, lists:nth(2, Shards), Acc1),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, lists:nth(3, Shards), Acc2
        ),
    ?assertEqual({error, [{Doc1, {ok, Doc1}}, {Doc2, {Doc2, {error, <<"foo">>}}}]}, Reply).

one_error_two_forbid() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),

    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, hd(Shards), Acc0
        ),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message({ok, [{ok, Doc1}, {Doc2, {error, <<"foo">>}}]}, lists:nth(2, Shards), Acc1),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, lists:nth(3, Shards), Acc2
        ),
    ?assertEqual(
        {error, [{Doc1, {ok, Doc1}}, {Doc2, {Doc2, {forbidden, <<"not allowed">>}}}]}, Reply
    ).

one_success_two_forbid() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Doc2 = #doc{revs = {1, [<<"bar">>]}},
    Docs = [Doc1, Doc2],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),

    Acc0 = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },

    {ok, #acc{waiting_count = WaitingCount1} = Acc1} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, hd(Shards), Acc0
        ),
    ?assertEqual(WaitingCount1, 2),

    {ok, #acc{waiting_count = WaitingCount2} = Acc2} =
        handle_message({ok, [{ok, Doc1}, {Doc2, {ok, Doc2}}]}, lists:nth(2, Shards), Acc1),
    ?assertEqual(WaitingCount2, 1),

    {stop, Reply} =
        handle_message(
            {ok, [{ok, Doc1}, {Doc2, {forbidden, <<"not allowed">>}}]}, lists:nth(3, Shards), Acc2
        ),
    ?assertEqual(
        {error, [{Doc1, {ok, Doc1}}, {Doc2, {Doc2, {forbidden, <<"not allowed">>}}}]}, Reply
    ).

worker_before_doc_update_forbidden() ->
    Doc1 = #doc{revs = {1, [<<"foo">>]}},
    Docs = [Doc1],
    Shards =
        mem3_util:create_partition_map("foo", 3, 1, ["node1", "node2", "node3"]),
    GroupedDocs = group_docs_by_shard_hack(<<"foo">>, Shards, Docs),
    Acc = #acc{
        waiting_count = length(Shards),
        doc_count = length(Docs),
        w = 2,
        grouped_docs = GroupedDocs,
        reply = dict:from_list([{Doc, []} || Doc <- Docs])
    },
    ?assertThrow({forbidden, <<"msg">>}, handle_message({forbidden, <<"msg">>}, hd(Shards), Acc)).

% needed for testing to avoid having to start the mem3 application
group_docs_by_shard_hack(_DbName, Shards, Docs) ->
    dict:to_list(
        lists:foldl(
            fun(#doc{id = _Id} = Doc, D0) ->
                lists:foldl(
                    fun(Shard, D1) ->
                        dict:append(Shard, Doc, D1)
                    end,
                    D0,
                    Shards
                )
            end,
            dict:new(),
            Docs
        )
    ).

-endif.
