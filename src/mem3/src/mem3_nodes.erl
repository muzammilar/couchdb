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

-module(mem3_nodes).
-behaviour(gen_server).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-export([start_link/0, get_nodelist/0, get_node_info/2]).

-include_lib("mem3/include/mem3.hrl").
-include_lib("couch/include/couch_db.hrl").

-record(state, {changes_pid, update_seq}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_nodelist() ->
    try
        lists:sort([N || {N, _} <- ets:tab2list(?MODULE)])
    catch
        error:badarg ->
            gen_server:call(?MODULE, get_nodelist)
    end.

get_node_info(Node, Key) ->
    try
        couch_util:get_value(Key, ets:lookup_element(?MODULE, Node, 2))
    catch
        error:badarg ->
            gen_server:call(?MODULE, {get_node_info, Node, Key})
    end.

init([]) ->
    DbName = mem3_sync:nodes_db(),
    ioq:set_io_priority({system, DbName}),
    ets:new(?MODULE, [named_table, {read_concurrency, true}]),
    UpdateSeq = initialize_nodelist(),
    {Pid, _} = spawn_monitor(fun() -> listen_for_changes(UpdateSeq) end),
    {ok, #state{changes_pid = Pid, update_seq = UpdateSeq}}.

handle_call(get_nodelist, _From, State) ->
    {reply, lists:sort([N || {N, _} <- ets:tab2list(?MODULE)]), State};
handle_call({get_node_info, Node, Key}, _From, State) ->
    Resp =
        try
            couch_util:get_value(Key, ets:lookup_element(?MODULE, Node, 2))
        catch
            error:badarg ->
                error
        end,
    {reply, Resp, State};
handle_call({add_node, Node, NodeInfo}, _From, State) ->
    gen_event:notify(mem3_events, {add_node, Node}),
    update_ets(Node, NodeInfo),
    {reply, ok, State};
handle_call({remove_node, Node}, _From, State) ->
    gen_event:notify(mem3_events, {remove_node, Node}),
    ets:delete(?MODULE, Node),
    {reply, ok, State};
handle_call(_Call, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _, _, Pid, Reason}, #state{changes_pid = Pid} = State) ->
    couch_log:notice("~p changes listener died ~p", [?MODULE, Reason]),
    StartSeq = State#state.update_seq,
    Seq =
        case Reason of
            {seq, EndSeq} -> EndSeq;
            _ -> StartSeq
        end,
    erlang:send_after(5000, self(), start_listener),
    {noreply, State#state{update_seq = Seq}};
handle_info(start_listener, #state{update_seq = Seq} = State) ->
    {NewPid, _} = spawn_monitor(fun() -> listen_for_changes(Seq) end),
    {noreply, State#state{changes_pid = NewPid}};
handle_info(_Info, State) ->
    {noreply, State}.

%% internal functions
initialize_nodelist() ->
    DbName = mem3_sync:nodes_db(),
    {ok, Db} = mem3_util:ensure_exists(DbName),
    {ok, _} = couch_db:fold_docs(Db, fun first_fold/2, Db, []),

    insert_if_missing(Db, [config:node_name() | mem3_seeds:get_seeds()]),

    % when creating the document for the local node, populate
    % the placement zone as defined by the COUCHDB_ZONE environment
    % variable. This is an additional update on top of the first,
    % empty document so that we don't create conflicting revisions
    % between different nodes in the cluster when using a seedlist.
    case os:getenv("COUCHDB_ZONE") of
        false ->
            % do not support unsetting a zone.
            ok;
        Zone ->
            set_zone(DbName, config:node_name(), ?l2b(Zone))
    end,

    Seq = couch_db:get_update_seq(Db),
    couch_db:close(Db),
    Seq.

first_fold(#full_doc_info{id = <<"_design/", _/binary>>}, Acc) ->
    {ok, Acc};
first_fold(#full_doc_info{deleted = true}, Acc) ->
    {ok, Acc};
first_fold(#full_doc_info{id = Id} = DocInfo, Db) ->
    {ok, #doc{body = {Props}}} = couch_db:open_doc(Db, DocInfo, [ejson_body]),
    update_ets(mem3_util:to_atom(Id), Props),
    {ok, Db}.

listen_for_changes(Since) ->
    DbName = mem3_sync:nodes_db(),
    ioq:set_io_priority({system, DbName}),
    {ok, Db} = mem3_util:ensure_exists(DbName),
    Args = #changes_args{
        feed = "continuous",
        since = Since,
        heartbeat = true,
        include_docs = true
    },
    ChangesFun = couch_changes:handle_db_changes(Args, nil, Db),
    ChangesFun(fun changes_callback/2).

changes_callback(start, _) ->
    {ok, nil};
changes_callback({stop, EndSeq}, _) ->
    exit({seq, EndSeq});
changes_callback({change, {Change}, _}, _) ->
    Node = couch_util:get_value(<<"id">>, Change),
    case Node of
        <<"_design/", _/binary>> ->
            ok;
        _ ->
            case mem3_util:is_deleted(Change) of
                false ->
                    {Props} = couch_util:get_value(doc, Change),
                    gen_server:call(?MODULE, {add_node, mem3_util:to_atom(Node), Props});
                true ->
                    gen_server:call(?MODULE, {remove_node, mem3_util:to_atom(Node)})
            end
    end,
    {ok, couch_util:get_value(<<"seq">>, Change)};
changes_callback(timeout, _) ->
    {ok, nil}.

insert_if_missing(Db, Nodes) ->
    Docs = lists:foldl(
        fun(Node, Acc) ->
            case ets:lookup(?MODULE, Node) of
                [_] ->
                    Acc;
                [] ->
                    update_ets(Node, []),
                    [#doc{id = couch_util:to_binary(Node)} | Acc]
            end
        end,
        [],
        Nodes
    ),
    if
        Docs =/= [] ->
            {ok, _} = couch_db:update_docs(Db, Docs, []);
        true ->
            {ok, []}
    end.

-spec update_ets(Node :: term(), NodeInfo :: [tuple()]) -> true.
update_ets(Node, NodeInfo) ->
    ets:insert(?MODULE, {Node, NodeInfo}).

% sets the placement zone for the given node document.
-spec set_zone(DbName :: binary(), Node :: string() | binary(), Zone :: binary()) -> ok.
set_zone(DbName, Node, Zone) ->
    {ok, Db} = couch_db:open(DbName, [sys_db, ?ADMIN_CTX]),
    Props = get_from_db(Db, Node),
    CurrentZone = couch_util:get_value(<<"zone">>, Props),
    case CurrentZone of
        Zone ->
            ok;
        _ ->
            couch_log:info("Setting node zone attribute to ~s~n", [Zone]),
            Props1 = couch_util:set_value(<<"zone">>, Props, Zone),
            save_to_db(Db, Node, Props1)
    end,
    couch_db:close(Db),
    ok.

% get a node document from the system nodes db as a property list
-spec get_from_db(Db :: any(), Node :: string() | binary()) -> [tuple()].
get_from_db(Db, Node) ->
    Id = couch_util:to_binary(Node),
    {ok, Doc} = couch_db:open_doc(Db, Id, [ejson_body]),
    {Props} = couch_doc:to_json_obj(Doc, []),
    Props.

% save a node document (represented as a property list)
% to the system nodes db and update the ETS cache.
-spec save_to_db(Db :: any(), Node :: string() | binary(), Props :: [tuple()]) -> ok.
save_to_db(Db, Node, Props) ->
    Doc = couch_doc:from_json_obj({Props}),
    #doc{body = {NodeInfo}} = Doc,
    {ok, _} = couch_db:update_doc(Db, Doc, []),
    update_ets(Node, NodeInfo),
    ok.
