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

-module(fabric_doc_open_revs).

-export([go/4]).

-include_lib("mem3/include/mem3.hrl").
-include_lib("couch/include/couch_db.hrl").

-record(state, {
    dbname,
    worker_count,
    workers,
    reply_count = 0,
    reply_error_count = 0,
    r,
    revs,
    latest,
    replies = [],
    node_revs = [],
    repair = false
}).

go(DbName, Id, Revs, Options) ->
    Workers = fabric_util:submit_jobs(
        mem3:shards(DbName, Id),
        open_revs,
        [Id, Revs, Options]
    ),
    R = couch_util:get_value(r, Options, integer_to_list(mem3:quorum(DbName))),
    State = #state{
        dbname = DbName,
        worker_count = length(Workers),
        workers = Workers,
        r = list_to_integer(R),
        revs = Revs,
        latest = lists:member(latest, Options),
        replies = []
    },
    RexiMon = fabric_util:create_monitors(Workers),
    try fabric_util:recv(Workers, #shard.ref, fun handle_message/3, State) of
        {ok, all_workers_died} ->
            {error, all_workers_died};
        {ok, Replies} ->
            {ok, Replies};
        {timeout, #state{workers = DefunctWorkers}} ->
            fabric_util:log_timeout(DefunctWorkers, "open_revs"),
            {error, timeout};
        Else ->
            Else
    after
        rexi_monitor:stop(RexiMon)
    end.

handle_message({rexi_DOWN, _, {_, NodeRef}, _}, _Worker, #state{workers = Workers} = State) ->
    NewState = State#state{
        workers = lists:keydelete(NodeRef, #shard.node, Workers),
        reply_error_count = State#state.reply_error_count + 1
    },
    handle_message({ok, []}, nil, NewState);
handle_message({rexi_EXIT, _}, Worker, #state{workers = Workers} = State) ->
    NewState = State#state{
        workers = lists:delete(Worker, Workers),
        reply_error_count = State#state.reply_error_count + 1
    },
    handle_message({ok, []}, nil, NewState);
handle_message({ok, RawReplies}, Worker, State) ->
    #state{
        dbname = DbName,
        reply_count = ReplyCount,
        worker_count = WorkerCount,
        workers = Workers,
        replies = PrevReplies,
        node_revs = PrevNodeRevs,
        r = R,
        revs = Revs,
        latest = Latest,
        repair = InRepair,
        reply_error_count = ReplyErrorCount
    } = State,

    IsTree = Revs == all orelse Latest,

    NewReplyCount = ReplyCount + 1,

    % Do not count error replies when checking quorum
    RealReplyCount = NewReplyCount - ReplyErrorCount,
    QuorumReplies = RealReplyCount >= R,
    {NewReplies, QuorumMet, Repair} =
        case IsTree of
            true ->
                {NewReplies0, AllInternal, Repair0} =
                    tree_replies(PrevReplies, tree_sort(RawReplies)),
                NumLeafs = couch_key_tree:count_leafs(PrevReplies),
                SameNumRevs = length(RawReplies) == NumLeafs,
                QMet = AllInternal andalso SameNumRevs andalso QuorumReplies,
                % Don't set repair=true on the first reply
                {NewReplies0, QMet, (ReplyCount > 0) and Repair0};
            false ->
                {NewReplies0, MinCount} = dict_replies(PrevReplies, RawReplies),
                {NewReplies0, MinCount >= R, false}
        end,

    NewNodeRevs = update_node_revs(Worker, RawReplies, PrevNodeRevs),

    Complete = (ReplyCount =:= (WorkerCount - 1)),

    case QuorumMet orelse Complete of
        true ->
            fabric_util:cleanup(lists:delete(Worker, Workers)),
            maybe_read_repair(
                DbName,
                IsTree,
                NewReplies,
                NewNodeRevs,
                NewReplyCount,
                InRepair orelse Repair
            ),
            {stop, format_reply(IsTree, NewReplies, RealReplyCount)};
        false ->
            {ok, State#state{
                replies = NewReplies,
                node_revs = NewNodeRevs,
                reply_count = NewReplyCount,
                workers = lists:delete(Worker, Workers),
                repair = InRepair orelse Repair
            }}
    end.

% Update node revs from the latest replies
%
update_node_revs(nil, _, PrevNodeRevs) ->
    % This handles the error cases when Worker is explicitly set to nil. (See
    % rexi_DOWN and rexi_EXIT clauses).
    PrevNodeRevs;
update_node_revs(Worker, RawReplies, PrevNodeRevs) ->
    FoldFun = fun
        ({ok, #doc{revs = {Pos, [Rev | _]}}}, Acc) ->
            [{Pos, Rev} | Acc];
        (_, Acc) ->
            Acc
    end,
    case lists:foldl(FoldFun, [], RawReplies) of
        [] ->
            PrevNodeRevs;
        [_ | _] = IdRevs ->
            [{Worker#shard.node, IdRevs} | PrevNodeRevs]
    end.

tree_replies(RevTree, []) ->
    {RevTree, true, false};
tree_replies(RevTree0, [{ok, Doc} | Rest]) ->
    {RevTree1, Done, Repair} = tree_replies(RevTree0, Rest),
    Path = couch_doc:to_path(Doc),
    case couch_key_tree:merge(RevTree1, Path) of
        {RevTree2, internal_node} ->
            {RevTree2, Done, Repair};
        {RevTree2, new_leaf} ->
            {RevTree2, Done, true};
        {RevTree2, _} ->
            {RevTree2, false, true}
    end;
tree_replies(RevTree0, [{{not_found, missing}, {Pos, Rev}} | Rest]) ->
    {RevTree1, Done, Repair} = tree_replies(RevTree0, Rest),
    Node = {Rev, ?REV_MISSING, []},
    Path = {Pos, Node},
    case couch_key_tree:merge(RevTree1, Path) of
        {RevTree2, internal_node} ->
            {RevTree2, Done, true};
        {RevTree2, _} ->
            {RevTree2, false, Repair}
    end.

tree_sort(Replies) ->
    SortFun = fun(A, B) -> sort_key(A) =< sort_key(B) end,
    lists:sort(SortFun, Replies).

sort_key({ok, #doc{revs = {Pos, [Rev | _]}}}) ->
    {Pos, Rev};
sort_key({{not_found, _}, {Pos, Rev}}) ->
    {Pos, Rev}.

dict_replies(Dict, []) ->
    case [Count || {_Key, {_Reply, Count}} <- Dict] of
        [] -> {Dict, 0};
        Counts -> {Dict, lists:min(Counts)}
    end;
dict_replies(Dict, [Reply | Rest]) ->
    NewDict = fabric_util:update_counter(Reply, 1, Dict),
    dict_replies(NewDict, Rest).

maybe_read_repair(Db, IsTree, Replies, NodeRevs, ReplyCount, DoRepair) ->
    % Do not read repair replicator docs because after_doc_read/2 callback
    % might have patched them with a fake rev and we wouldn't want to write
    % those back to disk. Let the internal replicator sync the shards instead.
    Docs =
        case {fabric_util:is_replicator_db(Db), IsTree} of
            {true, _} -> [];
            {_, true} -> tree_repair_docs(Replies, DoRepair);
            {_, false} -> dict_repair_docs(Replies, ReplyCount)
        end,
    case Docs of
        [] ->
            ok;
        _ ->
            erlang:spawn(fun() -> read_repair(Db, Docs, NodeRevs) end)
    end.

tree_repair_docs(_Replies, false) ->
    [];
tree_repair_docs(Replies, true) ->
    Leafs = couch_key_tree:get_all_leafs(Replies),
    [Doc || {Doc, {_Pos, _}} <- Leafs, is_record(Doc, doc)].

dict_repair_docs(Replies, ReplyCount) ->
    NeedsRepair = lists:any(fun({_, {_, C}}) -> C < ReplyCount end, Replies),
    if
        not NeedsRepair -> [];
        true -> [Doc || {_, {{ok, Doc}, _}} <- Replies]
    end.

read_repair(Db, Docs, NodeRevs) ->
    Opts = [?ADMIN_CTX, ?REPLICATED_CHANGES, {read_repair, NodeRevs}],
    Res = fabric:update_docs(Db, Docs, Opts),
    case Res of
        {ok, []} ->
            couch_stats:increment_counter([fabric, read_repairs, success]);
        _ ->
            couch_stats:increment_counter([fabric, read_repairs, failure]),
            [#doc{id = Id} | _] = Docs,
            couch_log:notice("read_repair ~s ~s ~p", [Db, Id, Res])
    end.

format_reply(_, _, RealReplyCount) when RealReplyCount =< 0 ->
    all_workers_died;
format_reply(true, Replies, _) ->
    tree_format_replies(Replies);
format_reply(false, Replies, _) ->
    dict_format_replies(Replies).

tree_format_replies(RevTree) ->
    Leafs = couch_key_tree:get_all_leafs(RevTree),
    lists:sort(
        lists:map(
            fun(Reply) ->
                case Reply of
                    {?REV_MISSING, {Pos, [Rev]}} ->
                        {{not_found, missing}, {Pos, Rev}};
                    {Doc, _} when is_record(Doc, doc) ->
                        {ok, Doc}
                end
            end,
            Leafs
        )
    ).

dict_format_replies(Dict) ->
    Replies0 = [Reply || {_, {Reply, _}} <- Dict],

    AllFoundRevs = lists:foldl(
        fun(Reply, Acc) ->
            case Reply of
                {ok, #doc{revs = {Pos, [RevId | _]}}} ->
                    [{Pos, RevId} | Acc];
                _ ->
                    Acc
            end
        end,
        [],
        Replies0
    ),

    %% Drop any not_found replies for which we
    %% found the revision on a different node.
    Replies1 = lists:filter(
        fun(Reply) ->
            case Reply of
                {{not_found, missing}, Rev} ->
                    not lists:member(Rev, AllFoundRevs);
                _ ->
                    true
            end
        end,
        Replies0
    ),

    % Remove replies with shorter revision
    % paths for a given revision.
    collapse_duplicate_revs(Replies1).

collapse_duplicate_revs(Replies) ->
    % The collapse logic requires that replies are
    % sorted so that shorter rev paths are in
    % the list just before longer lists.
    %
    % This somewhat implicitly relies on Erlang's
    % sorting of [A, B] < [A, B, C] for all values
    % of C.
    collapse_duplicate_revs_int(lists:sort(Replies)).

collapse_duplicate_revs_int([]) ->
    [];
collapse_duplicate_revs_int([{ok, Doc1}, {ok, Doc2} | Rest]) ->
    {D1, R1} = Doc1#doc.revs,
    {D2, R2} = Doc2#doc.revs,
    Head =
        case D1 == D2 andalso lists:prefix(R1, R2) of
            true -> [];
            false -> [{ok, Doc1}]
        end,
    Head ++ collapse_duplicate_revs([{ok, Doc2} | Rest]);
collapse_duplicate_revs_int([Reply | Rest]) ->
    [Reply | collapse_duplicate_revs(Rest)].

-ifdef(TEST).
-include_lib("couch/include/couch_eunit.hrl").

setup_all() ->
    config:start_link([]),
    meck:new([fabric, couch_stats, couch_log]),
    meck:new(fabric_util, [passthrough]),
    meck:expect(fabric, update_docs, fun(_, _, _) -> {ok, nil} end),
    meck:expect(couch_stats, increment_counter, fun(_) -> ok end),
    meck:expect(couch_log, notice, fun(_, _) -> ok end),
    meck:expect(fabric_util, cleanup, fun(_) -> ok end).

teardown_all(_) ->
    meck:unload(),
    config:stop().

setup() ->
    meck:reset([
        couch_log,
        couch_stats,
        fabric,
        fabric_util
    ]).

teardown(_) ->
    ok.

state0(Revs, Latest) ->
    #state{
        dbname = <<"dbname">>,
        worker_count = 3,
        workers =
            [#shard{node = 'node1'}, #shard{node = 'node2'}, #shard{node = 'node3'}],
        r = 2,
        revs = Revs,
        latest = Latest
    }.

revs() -> [{1, <<"foo">>}, {1, <<"bar">>}, {1, <<"baz">>}].

foo1() -> {ok, #doc{revs = {1, [<<"foo">>]}}}.
foo2() -> {ok, #doc{revs = {2, [<<"foo2">>, <<"foo">>]}}}.
foo2stemmed() -> {ok, #doc{revs = {2, [<<"foo2">>]}}}.
fooNF() -> {{not_found, missing}, {1, <<"foo">>}}.
foo2NF() -> {{not_found, missing}, {2, <<"foo2">>}}.
bar1() -> {ok, #doc{revs = {1, [<<"bar">>]}}}.
barNF() -> {{not_found, missing}, {1, <<"bar">>}}.
bazNF() -> {{not_found, missing}, {1, <<"baz">>}}.
baz1() -> {ok, #doc{revs = {1, [<<"baz">>]}}}.

open_doc_revs_test_() ->
    {
        setup,
        fun setup_all/0,
        fun teardown_all/1,
        {
            foreach,
            fun setup/0,
            fun teardown/1,
            [
                ?TDEF_FE(check_empty_response_not_quorum),
                ?TDEF_FE(check_basic_response),
                ?TDEF_FE(check_finish_quorum),
                ?TDEF_FE(check_finish_quorum_newer),
                ?TDEF_FE(check_finish_quorum_replicator),
                ?TDEF_FE(check_no_quorum_on_second),
                ?TDEF_FE(check_done_on_third),
                ?TDEF_FE(check_specific_revs_first_msg),
                ?TDEF_FE(check_revs_done_on_agreement),
                ?TDEF_FE(check_latest_true),
                ?TDEF_FE(check_ancestor_counted_in_quorum),
                ?TDEF_FE(check_not_found_counts_for_descendant),
                ?TDEF_FE(check_worker_error_skipped),
                ?TDEF_FE(check_quorum_only_counts_valid_responses),
                ?TDEF_FE(check_empty_list_when_no_workers_reply),
                ?TDEF_FE(check_node_rev_stored),
                ?TDEF_FE(check_node_rev_store_head_only),
                ?TDEF_FE(check_node_rev_store_multiple),
                ?TDEF_FE(check_node_rev_dont_store_errors),
                ?TDEF_FE(check_node_rev_store_non_errors),
                ?TDEF_FE(check_node_rev_store_concatenate),
                ?TDEF_FE(check_node_rev_store_concantenate_multiple),
                ?TDEF_FE(check_node_rev_unmodified_on_down_or_exit),
                ?TDEF_FE(check_not_found_replies_are_removed_when_doc_found),
                ?TDEF_FE(check_not_found_returned_when_one_of_docs_not_found),
                ?TDEF_FE(check_not_found_returned_when_doc_not_found),
                ?TDEF_FE(check_longer_rev_list_returned),
                ?TDEF_FE(check_longer_rev_list_not_combined),
                ?TDEF_FE(check_not_found_removed_and_longer_rev_list)
            ]
        }
    }.

% Tests for revs=all

check_empty_response_not_quorum(_) ->
    % Simple smoke test that we don't think we're
    % done with a first empty response
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    W3 = #shard{node = 'node3'},
    ?assertMatch(
        {ok, #state{workers = [W2, W3]}},
        handle_message({ok, []}, W1, state0(all, false))
    ).

check_basic_response(_) ->
    % Check that we've handle a response
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    W3 = #shard{node = 'node3'},
    ?assertMatch(
        {ok, #state{reply_count = 1, workers = [W2, W3]}},
        handle_message({ok, [foo1(), bar1()]}, W1, state0(all, false))
    ).

check_finish_quorum(_) ->
    % Two messages with the same revisions means we're done
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    S0 = state0(all, false),
    {ok, S1} = handle_message({ok, [foo1(), bar1()]}, W1, S0),
    Expect = {stop, [bar1(), foo1()]},
    ?assertEqual(Expect, handle_message({ok, [foo1(), bar1()]}, W2, S1)).

check_finish_quorum_newer(_) ->
    % We count a descendant of a revision for quorum so
    % foo1 should count for foo2 which means we're finished.
    % We also validate that read_repair was triggered.
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    S0 = state0(all, false),
    {ok, S1} = handle_message({ok, [foo1(), bar1()]}, W1, S0),
    Expect = {stop, [bar1(), foo2()]},
    meck:reset(fabric),
    ?assertEqual(Expect, handle_message({ok, [foo2(), bar1()]}, W2, S1)),
    meck:wait(fabric, update_docs, '_', 5000),
    ?assertMatch(
        [{_, {fabric, update_docs, [_, _, _]}, _}],
        meck:history(fabric)
    ).

check_finish_quorum_replicator(_) ->
    % We count a descendant of a revision for quorum so
    % foo1 should count for foo2 which means we're finished.
    % Since we use a replicator shard read_repair doesn't trigger
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    S0 = state0(all, false),
    S1 = S0#state{dbname = <<"foo/_replicator">>},
    {ok, S2} = handle_message({ok, [foo1(), bar1()]}, W1, S1),
    Expect = {stop, [bar1(), foo2()]},
    meck:reset(fabric),
    ?assertEqual(Expect, handle_message({ok, [foo2(), bar1()]}, W2, S2)),
    timer:sleep(100),
    ?assertNot(meck:called(fabric, update_docs, ['_', '_', '_'])).

check_no_quorum_on_second(_) ->
    % Quorum not yet met for the foo revision so we
    % would wait for w3
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    W3 = #shard{node = 'node3'},
    S0 = state0(all, false),
    {ok, S1} = handle_message({ok, [foo1(), bar1()]}, W1, S0),
    ?assertMatch(
        {ok, #state{workers = [W3]}},
        handle_message({ok, [bar1()]}, W2, S1)
    ).

check_done_on_third(_) ->
    % The third message of three means we're done no matter
    % what. Every revision seen in this pattern should be
    % included.
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    W3 = #shard{node = 'node3'},
    S0 = state0(all, false),
    {ok, S1} = handle_message({ok, [foo1(), bar1()]}, W1, S0),
    {ok, S2} = handle_message({ok, [bar1()]}, W2, S1),
    Expect = {stop, [bar1(), foo1()]},
    ?assertEqual(Expect, handle_message({ok, [bar1()]}, W3, S2)).

% Tests for a specific list of revs

check_specific_revs_first_msg(_) ->
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    W3 = #shard{node = 'node3'},
    S0 = state0(revs(), false),
    ?assertMatch(
        {ok, #state{reply_count = 1, workers = [W2, W3]}},
        handle_message({ok, [foo1(), bar1(), bazNF()]}, W1, S0)
    ).

check_revs_done_on_agreement(_) ->
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    S0 = state0(revs(), false),
    Msg = {ok, [foo1(), bar1(), bazNF()]},
    {ok, S1} = handle_message(Msg, W1, S0),
    Expect = {stop, [bar1(), foo1(), bazNF()]},
    ?assertEqual(Expect, handle_message(Msg, W2, S1)).

check_latest_true(_) ->
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    S0 = state0(revs(), true),
    Msg1 = {ok, [foo2(), bar1(), bazNF()]},
    Msg2 = {ok, [foo2(), bar1(), bazNF()]},
    {ok, S1} = handle_message(Msg1, W1, S0),
    Expect = {stop, [bar1(), foo2(), bazNF()]},
    ?assertEqual(Expect, handle_message(Msg2, W2, S1)).

check_ancestor_counted_in_quorum(_) ->
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    S0 = state0(revs(), true),
    Msg1 = {ok, [foo1(), bar1(), bazNF()]},
    Msg2 = {ok, [foo2(), bar1(), bazNF()]},
    Expect = {stop, [bar1(), foo2(), bazNF()]},

    % Older first
    {ok, S1} = handle_message(Msg1, W1, S0),
    ?assertEqual(Expect, handle_message(Msg2, W2, S1)),

    % Newer first
    {ok, S2} = handle_message(Msg2, W2, S0),
    ?assertEqual(Expect, handle_message(Msg1, W1, S2)).

check_not_found_counts_for_descendant(_) ->
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    S0 = state0(revs(), true),
    Msg1 = {ok, [foo1(), bar1(), bazNF()]},
    Msg2 = {ok, [foo1(), bar1(), baz1()]},
    Expect = {stop, [bar1(), baz1(), foo1()]},

    % not_found first
    {ok, S1} = handle_message(Msg1, W1, S0),
    ?assertEqual(Expect, handle_message(Msg2, W2, S1)),

    % not_found second
    {ok, S2} = handle_message(Msg2, W2, S0),
    ?assertEqual(Expect, handle_message(Msg1, W1, S2)).

check_worker_error_skipped(_) ->
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    W3 = #shard{node = 'node3'},
    S0 = state0(revs(), true),
    Msg1 = {ok, [foo1(), bar1(), baz1()]},
    Msg2 = {rexi_EXIT, reason},
    Msg3 = {ok, [foo1(), bar1(), baz1()]},
    Expect = {stop, [bar1(), baz1(), foo1()]},

    {ok, S1} = handle_message(Msg1, W1, S0),
    {ok, S2} = handle_message(Msg2, W2, S1),
    ?assertEqual(Expect, handle_message(Msg3, W3, S2)).

check_quorum_only_counts_valid_responses(_) ->
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    W3 = #shard{node = 'node3'},
    S0 = state0(revs(), true),
    Msg1 = {rexi_EXIT, reason},
    Msg2 = {rexi_EXIT, reason},
    Msg3 = {ok, [foo1(), bar1(), baz1()]},
    Expect = {stop, [bar1(), baz1(), foo1()]},

    {ok, S1} = handle_message(Msg1, W1, S0),
    {ok, S2} = handle_message(Msg2, W2, S1),
    ?assertEqual(Expect, handle_message(Msg3, W3, S2)).

check_empty_list_when_no_workers_reply(_) ->
    W1 = #shard{node = 'node1'},
    W2 = #shard{node = 'node2'},
    W3 = #shard{node = 'node3'},
    S0 = state0(revs(), true),
    Msg1 = {rexi_EXIT, reason},
    Msg2 = {rexi_EXIT, reason},
    Msg3 = {rexi_DOWN, nodedown, {nil, node()}, nil},
    Expect = {stop, all_workers_died},

    {ok, S1} = handle_message(Msg1, W1, S0),
    {ok, S2} = handle_message(Msg2, W2, S1),
    ?assertEqual(Expect, handle_message(Msg3, W3, S2)).

check_node_rev_stored(_) ->
    W1 = #shard{node = node1},
    S0 = state0([], true),

    {ok, S1} = handle_message({ok, [foo1()]}, W1, S0),
    ?assertEqual([{node1, [{1, <<"foo">>}]}], S1#state.node_revs).

check_node_rev_store_head_only(_) ->
    W1 = #shard{node = node1},
    S0 = state0([], true),

    {ok, S1} = handle_message({ok, [foo2()]}, W1, S0),
    ?assertEqual([{node1, [{2, <<"foo2">>}]}], S1#state.node_revs).

check_node_rev_store_multiple(_) ->
    W1 = #shard{node = node1},
    S0 = state0([], true),

    {ok, S1} = handle_message({ok, [foo1(), foo2()]}, W1, S0),
    ?assertEqual(
        [{node1, [{2, <<"foo2">>}, {1, <<"foo">>}]}],
        S1#state.node_revs
    ).

check_node_rev_dont_store_errors(_) ->
    W1 = #shard{node = node1},
    S0 = state0([], true),

    {ok, S1} = handle_message({ok, [barNF()]}, W1, S0),
    ?assertEqual([], S1#state.node_revs).

check_node_rev_store_non_errors(_) ->
    W1 = #shard{node = node1},
    S0 = state0([], true),

    {ok, S1} = handle_message({ok, [foo1(), barNF()]}, W1, S0),
    ?assertEqual([{node1, [{1, <<"foo">>}]}], S1#state.node_revs).

check_node_rev_store_concatenate(_) ->
    W2 = #shard{node = node2},
    S0 = state0([], true),
    S1 = S0#state{node_revs = [{node1, [{1, <<"foo">>}]}]},

    {ok, S2} = handle_message({ok, [foo2()]}, W2, S1),
    ?assertEqual(
        [{node2, [{2, <<"foo2">>}]}, {node1, [{1, <<"foo">>}]}],
        S2#state.node_revs
    ).

check_node_rev_store_concantenate_multiple(_) ->
    W2 = #shard{node = node2},
    S0 = state0([], true),
    S1 = S0#state{node_revs = [{node1, [{1, <<"foo">>}]}]},

    {ok, S2} = handle_message({ok, [foo2(), bar1()]}, W2, S1),
    ?assertEqual(
        [
            {node2, [{1, <<"bar">>}, {2, <<"foo2">>}]},
            {node1, [{1, <<"foo">>}]}
        ],
        S2#state.node_revs
    ).

check_node_rev_unmodified_on_down_or_exit(_) ->
    W2 = #shard{node = node2},
    S0 = state0([], true),
    S1 = S0#state{node_revs = [{node1, [{1, <<"foo">>}]}]},

    Down = {rexi_DOWN, nodedown, {nil, node()}, nil},
    {ok, S2} = handle_message(Down, W2, S1),
    ?assertEqual(
        [{node1, [{1, <<"foo">>}]}],
        S2#state.node_revs
    ),

    Exit = {rexi_EXIT, reason},
    {ok, S3} = handle_message(Exit, W2, S1),
    ?assertEqual(
        [{node1, [{1, <<"foo">>}]}],
        S3#state.node_revs
    ).

check_not_found_replies_are_removed_when_doc_found(_) ->
    Replies = replies_to_dict([foo1(), bar1(), fooNF()]),
    Expect = [bar1(), foo1()],
    ?assertEqual(Expect, dict_format_replies(Replies)).

check_not_found_returned_when_one_of_docs_not_found(_) ->
    Replies = replies_to_dict([foo1(), foo2(), barNF()]),
    Expect = [foo1(), foo2(), barNF()],
    ?assertEqual(Expect, dict_format_replies(Replies)).

check_not_found_returned_when_doc_not_found(_) ->
    Replies = replies_to_dict([fooNF(), barNF(), bazNF()]),
    Expect = [barNF(), bazNF(), fooNF()],
    ?assertEqual(Expect, dict_format_replies(Replies)).

check_longer_rev_list_returned(_) ->
    Replies = replies_to_dict([foo2(), foo2stemmed()]),
    Expect = [foo2()],
    ?assertEqual(2, length(Replies)),
    ?assertEqual(Expect, dict_format_replies(Replies)).

check_longer_rev_list_not_combined(_) ->
    Replies = replies_to_dict([foo2(), foo2stemmed(), bar1()]),
    Expect = [bar1(), foo2()],
    ?assertEqual(3, length(Replies)),
    ?assertEqual(Expect, dict_format_replies(Replies)).

check_not_found_removed_and_longer_rev_list(_) ->
    Replies = replies_to_dict([foo2(), foo2stemmed(), foo2NF()]),
    Expect = [foo2()],
    ?assertEqual(3, length(Replies)),
    ?assertEqual(Expect, dict_format_replies(Replies)).

replies_to_dict(Replies) ->
    [reply_to_element(R) || R <- Replies].

reply_to_element({ok, #doc{revs = Revs}} = Reply) ->
    {_, [Rev | _]} = Revs,
    {{Rev, Revs}, {Reply, 1}};
reply_to_element(Reply) ->
    {Reply, {Reply, 1}}.

-endif.
