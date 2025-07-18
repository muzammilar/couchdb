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

-module(couch_mrview).

-export([validate/2]).
-export([query_all_docs/2, query_all_docs/4]).
-export([query_view/3, query_view/4, query_view/6, get_view_index_pid/4]).
-export([get_info/2]).
-export([trigger_update/2, trigger_update/3]).
-export([get_view_info/3]).
-export([refresh/2]).
-export([compact/2, compact/3, cancel_compaction/2]).
-export([cleanup/1]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").

-define(MAX_RANK, 100).

-record(mracc, {
    db,
    meta_sent = false,
    total_rows,
    offset,
    limit,
    skip,
    group_level,
    doc_info,
    callback,
    user_acc,
    last_go = ok,
    reduce_fun,
    finalizer,
    update_seq,
    args
}).

validate_ddoc_fields(DDoc) ->
    MapFuncType = map_function_type(DDoc),
    lists:foreach(
        fun(Path) ->
            validate_ddoc_fields(DDoc, Path)
        end,
        [
            [{<<"filters">>, object}, {any, [object, string]}],
            [{<<"language">>, string}],
            [{<<"lists">>, object}, {any, [object, string]}],
            [{<<"options">>, object}],
            [{<<"options">>, object}, {<<"include_design">>, boolean}],
            [{<<"options">>, object}, {<<"local_seq">>, boolean}],
            [{<<"options">>, object}, {<<"partitioned">>, boolean}],
            [{<<"rewrites">>, [string, array]}],
            [{<<"shows">>, object}, {any, [object, string]}],
            [{<<"updates">>, object}, {any, [object, string]}],
            [{<<"validate_doc_update">>, string}],
            [{<<"views">>, object}, {<<"lib">>, object}],
            [{<<"views">>, object}, {any, object}, {<<"map">>, MapFuncType}],
            [{<<"views">>, object}, {any, object}, {<<"reduce">>, string}]
        ]
    ),
    require_map_function_for_views(DDoc),
    ok.

require_map_function_for_views({Props}) ->
    case couch_util:get_value(<<"views">>, Props) of
        undefined ->
            ok;
        {Views} ->
            lists:foreach(
                fun
                    ({<<"lib">>, _}) ->
                        ok;
                    ({Key, {Value}}) ->
                        case couch_util:get_value(<<"map">>, Value) of
                            undefined ->
                                throw(
                                    {invalid_design_doc,
                                        <<"View `", Key/binary, "` must contain map function">>}
                                );
                            _ ->
                                ok
                        end
                end,
                Views
            ),
            ok
    end.

validate_ddoc_fields(DDoc, Path) ->
    case validate_ddoc_fields(DDoc, Path, []) of
        ok ->
            ok;
        {error, {FailedPath0, Type0}} ->
            FailedPath = iolist_to_binary(join(FailedPath0, <<".">>)),
            Type = format_type(Type0),
            throw(
                {invalid_design_doc,
                    <<"`", FailedPath/binary, "` field must have ", Type/binary, " type">>}
            )
    end.

validate_ddoc_fields(undefined, _, _) ->
    ok;
validate_ddoc_fields(_, [], _) ->
    ok;
validate_ddoc_fields({KVS} = Props, [{any, Type} | Rest], Acc) ->
    lists:foldl(
        fun
            ({Key, _}, ok) ->
                validate_ddoc_fields(Props, [{Key, Type} | Rest], Acc);
            ({_, _}, {error, _} = Error) ->
                Error
        end,
        ok,
        KVS
    );
validate_ddoc_fields({KVS} = Props, [{Key, Type} | Rest], Acc) ->
    case validate_ddoc_field(Props, {Key, Type}) of
        ok ->
            validate_ddoc_fields(
                couch_util:get_value(Key, KVS),
                Rest,
                [Key | Acc]
            );
        error ->
            {error, {[Key | Acc], Type}};
        {error, Key1} ->
            {error, {[Key1 | Acc], Type}}
    end.

validate_ddoc_field(undefined, Type) when is_atom(Type) ->
    ok;
validate_ddoc_field(_, any) ->
    ok;
validate_ddoc_field(Value, Types) when is_list(Types) ->
    lists:foldl(
        fun
            (_, ok) -> ok;
            (Type, _) -> validate_ddoc_field(Value, Type)
        end,
        error,
        Types
    );
validate_ddoc_field(Value, string) when is_binary(Value) ->
    ok;
validate_ddoc_field(Value, array) when is_list(Value) ->
    ok;
validate_ddoc_field({Value}, object) when is_list(Value) ->
    ok;
validate_ddoc_field(Value, boolean) when is_boolean(Value) ->
    ok;
validate_ddoc_field({Props}, {any, Type}) ->
    validate_ddoc_field1(Props, Type);
validate_ddoc_field({Props}, {Key, Type}) ->
    validate_ddoc_field(couch_util:get_value(Key, Props), Type);
validate_ddoc_field(_, _) ->
    error.

validate_ddoc_field1([], _) ->
    ok;
validate_ddoc_field1([{Key, Value} | Rest], Type) ->
    case validate_ddoc_field(Value, Type) of
        ok ->
            validate_ddoc_field1(Rest, Type);
        error ->
            {error, Key}
    end.

map_function_type({Props}) ->
    case couch_util:get_value(<<"language">>, Props) of
        <<"query">> -> object;
        _ -> string
    end.

format_type(Type) when is_atom(Type) ->
    ?l2b(atom_to_list(Type));
format_type(Types) when is_list(Types) ->
    iolist_to_binary(join(lists:map(fun atom_to_list/1, Types), <<" or ">>)).

join(L, Sep) ->
    join(L, Sep, []).
join([H | []], _, Acc) ->
    [H | Acc];
join([H | T], Sep, Acc) ->
    join(T, Sep, [Sep, H | Acc]).

validate(Db, DDoc) ->
    ok = validate_ddoc_fields(DDoc#doc.body),
    GetName = fun
        (#mrview{map_names = [Name | _]}) -> Name;
        (#mrview{reduce_funs = [{Name, _} | _]}) -> Name;
        (_) -> null
    end,
    ValidateView = fun(Proc, #mrview{def = MapSrc, reduce_funs = Reds} = View) ->
        couch_query_servers:try_compile(Proc, map, GetName(View), MapSrc),
        lists:foreach(
            fun
                ({_RedName, <<"_sum", _/binary>>}) ->
                    ok;
                ({_RedName, <<"_count", _/binary>>}) ->
                    ok;
                ({_RedName, <<"_stats", _/binary>>}) ->
                    ok;
                ({_RedName, <<"_approx_count_distinct", _/binary>>}) ->
                    ok;
                ({_RedName, <<"_top_", N/binary>>}) ->
                    ok = check_rank(N);
                ({_RedName, <<"_bottom_", N/binary>>}) ->
                    ok = check_rank(N);
                ({_RedName, <<"_first", _/binary>>}) ->
                    ok;
                ({_RedName, <<"_last", _/binary>>}) ->
                    ok;
                ({_RedName, <<"_", _/binary>> = Bad}) ->
                    Msg = ["`", Bad, "` is not a supported reduce function."],
                    throw({invalid_design_doc, Msg});
                ({RedName, RedSrc}) ->
                    couch_query_servers:try_compile(Proc, reduce, RedName, RedSrc)
            end,
            Reds
        )
    end,
    {ok, #mrst{
        language = Lang,
        views = Views,
        partitioned = Partitioned
    }} = couch_mrview_util:ddoc_to_mrst(couch_db:name(Db), DDoc),

    case {couch_db:is_partitioned(Db), Partitioned} of
        {false, true} ->
            throw(
                {invalid_design_doc, <<
                    "partitioned option cannot be true in a "
                    "non-partitioned database."
                >>}
            );
        {_, _} ->
            ok
    end,

    try Views =/= [] andalso couch_query_servers:get_os_process(Lang) of
        false ->
            ok;
        Proc ->
            try
                lists:foreach(fun(V) -> ValidateView(Proc, V) end, Views)
            after
                couch_query_servers:ret_os_process(Proc)
            end
    catch
        {unknown_query_language, _Lang} ->
            %% Allow users to save ddocs written in unknown languages
            ok
    end.

check_rank(<<N/binary>>) ->
    try binary_to_integer(N) of
        Val when Val >= 1 andalso Val =< ?MAX_RANK ->
            ok;
        _ ->
            Msg = ["rank value must be between 1 and ", integer_to_list(?MAX_RANK)],
            throw({invalid_design_doc, Msg})
    catch
        error:badarg ->
            throw({invalid_design_doc, "invalid rank reducer"})
    end.

query_all_docs(Db, Args) ->
    query_all_docs(Db, Args, fun default_cb/2, []).

query_all_docs(Db, Args, Callback, Acc) when is_list(Args) ->
    Args1 = couch_mrview_util:validate_all_docs_args(Db, to_mrargs(Args)),
    query_all_docs(Db, Args1, Callback, Acc);
query_all_docs(Db, Args0, Callback, Acc) ->
    Sig = couch_util:with_db(Db, fun(WDb) ->
        {ok, Info} = couch_db:get_db_info(WDb),
        couch_index_util:hexsig(couch_hash:md5_hash(?term_to_bin(Info)))
    end),
    Args1 = Args0#mrargs{view_type = map},

    % TODO: Compatibility clause. Remove after upgrading to next minor release
    % after 3.5.0.
    %
    % As of commit 7aa8a4, args are validated in fabric. However, during online
    % cluster upgrades, old nodes will still expect args to be validated on
    % workers, so keep the clause around until the next minor version then
    % remove.
    %
    Args2 = couch_mrview_util:validate_all_docs_args(Db, Args1),
    {ok, Acc1} =
        case Args2#mrargs.preflight_fun of
            PFFun when is_function(PFFun, 2) -> PFFun(Sig, Acc);
            _ -> {ok, Acc}
        end,
    all_docs_fold(Db, Args2, Callback, Acc1).

query_view(Db, DDoc, VName) ->
    Args = #mrargs{extra = [{view_row_map, true}]},
    query_view(Db, DDoc, VName, Args).

query_view(Db, DDoc, VName, Args) when is_list(Args) ->
    query_view(Db, DDoc, VName, to_mrargs(Args), fun default_cb/2, []);
query_view(Db, DDoc, VName, Args) ->
    query_view(Db, DDoc, VName, Args, fun default_cb/2, []).

query_view(Db, DDoc, VName, Args, Callback, Acc) when is_list(Args) ->
    query_view(Db, DDoc, VName, to_mrargs(Args), Callback, Acc);
query_view(Db, DDoc, VName, Args0, Callback, Acc0) ->
    case couch_mrview_util:get_view(Db, DDoc, VName, Args0) of
        {ok, VInfo, Sig, Args} ->
            {ok, Acc1} =
                case Args#mrargs.preflight_fun of
                    PFFun when is_function(PFFun, 2) -> PFFun(Sig, Acc0);
                    _ -> {ok, Acc0}
                end,
            query_view(Db, VInfo, Args, Callback, Acc1);
        Error when Error == ddoc_updated; Error == insufficient_storage ->
            Callback(ok, Error)
    end.

get_view_index_pid(Db, DDoc, ViewName, Args0) ->
    couch_mrview_util:get_view_index_pid(Db, DDoc, ViewName, Args0).

query_view(Db, {Type, View, Ref}, Args, Callback, Acc) ->
    try
        case Type of
            map -> map_fold(Db, View, Args, Callback, Acc);
            red -> red_fold(Db, View, Args, Callback, Acc)
        end
    after
        erlang:demonitor(Ref, [flush])
    end.

get_info(Db, DDoc) ->
    {ok, Pid} = couch_index_server:get_index(couch_mrview_index, Db, DDoc),
    couch_index:get_info(Pid).

trigger_update(Db, DDoc) ->
    trigger_update(Db, DDoc, couch_db:get_update_seq(Db)).

trigger_update(Db, DDoc, UpdateSeq) ->
    {ok, Pid} = couch_index_server:get_index(couch_mrview_index, Db, DDoc),
    couch_index:trigger_update(Pid, UpdateSeq).

%% get informations on a view
get_view_info(Db, DDoc, VName) ->
    {ok, {_, View, _}, _, _Args} = couch_mrview_util:get_view(
        Db,
        DDoc,
        VName,
        #mrargs{extra = [{view_row_map, true}]}
    ),

    %% get the total number of rows
    {ok, TotalRows} = couch_mrview_util:get_row_count(View),

    {ok, [
        {update_seq, View#mrview.update_seq},
        {purge_seq, View#mrview.purge_seq},
        {total_rows, TotalRows}
    ]}.

%% @doc refresh a view index
refresh(DbName, DDoc) when is_binary(DbName) ->
    UpdateSeq = couch_util:with_db(DbName, fun(WDb) ->
        couch_db:get_update_seq(WDb)
    end),

    case couch_index_server:get_index(couch_mrview_index, DbName, DDoc) of
        {ok, Pid} ->
            case catch couch_index:get_state(Pid, UpdateSeq) of
                {ok, _} -> ok;
                Error -> {error, Error}
            end;
        Error ->
            {error, Error}
    end;
refresh(Db, DDoc) ->
    refresh(couch_db:name(Db), DDoc).

compact(Db, DDoc) ->
    compact(Db, DDoc, []).

compact(Db, DDoc, Opts) ->
    {ok, Pid} = couch_index_server:get_index(couch_mrview_index, Db, DDoc),
    couch_index:compact(Pid, Opts).

cancel_compaction(Db, DDoc) ->
    {ok, IPid} = couch_index_server:get_index(couch_mrview_index, Db, DDoc),
    {ok, CPid} = couch_index:get_compactor_pid(IPid),
    ok = couch_index_compactor:cancel(CPid),

    % Cleanup the compaction file if it exists
    {ok, #mrst{sig = Sig, db_name = DbName}} = couch_index:get_state(IPid, 0),
    couch_mrview_util:delete_compaction_file(DbName, Sig),
    ok.

cleanup(Db) ->
    couch_mrview_cleanup:run(Db).

all_docs_fold(Db, #mrargs{keys = undefined} = Args, Callback, UAcc) ->
    ReduceFun = get_reduce_fun(Args),
    Total = get_total_rows(Db, Args),
    UpdateSeq = get_update_seq(Db, Args),
    Acc = #mracc{
        db = Db,
        total_rows = Total,
        limit = Args#mrargs.limit,
        skip = Args#mrargs.skip,
        callback = Callback,
        user_acc = UAcc,
        reduce_fun = ReduceFun,
        update_seq = UpdateSeq,
        args = Args
    },
    [Opts1] = couch_mrview_util:all_docs_key_opts(Args),
    % TODO: This is a terrible hack for now. We'll probably have
    % to rewrite _all_docs to not be part of mrview and not expect
    % a btree. For now non-btree's will just have to pass 0 or
    % some fake reductions to get an offset.
    Opts2 = [include_reductions | Opts1],
    FunName =
        case couch_util:get_value(namespace, Args#mrargs.extra) of
            <<"_design">> -> fold_design_docs;
            <<"_local">> -> fold_local_docs;
            _ -> fold_docs
        end,
    {ok, Offset, FinalAcc} = couch_db:FunName(Db, fun map_fold/3, Acc, Opts2),
    finish_fold(FinalAcc, [{total, Total}, {offset, Offset}]);
all_docs_fold(Db, #mrargs{direction = Dir, keys = Keys0} = Args, Callback, UAcc) ->
    ReduceFun = get_reduce_fun(Args),
    Total = get_total_rows(Db, Args),
    UpdateSeq = get_update_seq(Db, Args),
    Acc = #mracc{
        db = Db,
        total_rows = Total,
        limit = Args#mrargs.limit,
        skip = Args#mrargs.skip,
        callback = Callback,
        user_acc = UAcc,
        reduce_fun = ReduceFun,
        update_seq = UpdateSeq,
        args = Args
    },
    % Backwards compatibility hack. The old _all_docs iterates keys
    % in reverse if descending=true was passed. Here we'll just
    % reverse the list instead.
    Keys =
        if
            Dir =:= fwd -> Keys0;
            true -> lists:reverse(Keys0)
        end,

    FoldFun = fun(Key, Acc0) ->
        DocInfo = (catch couch_db:get_doc_info(Db, Key)),
        {Doc, Acc1} =
            case DocInfo of
                {ok, #doc_info{id = Id, revs = [RevInfo | _RestRevs]} = DI} ->
                    Rev = couch_doc:rev_to_str(RevInfo#rev_info.rev),
                    Props =
                        [{rev, Rev}] ++
                            case RevInfo#rev_info.deleted of
                                true -> [{deleted, true}];
                                false -> []
                            end,
                    {{{Id, Id}, {Props}}, Acc0#mracc{doc_info = DI}};
                not_found ->
                    {{{Key, error}, not_found}, Acc0}
            end,
        {_, Acc2} = map_fold(Doc, {[], [{0, 0, 0}]}, Acc1),
        Acc2
    end,
    FinalAcc = lists:foldl(FoldFun, Acc, Keys),
    finish_fold(FinalAcc, [{total, Total}]).

map_fold(Db, View, Args, Callback, UAcc) ->
    {ok, Total} = couch_mrview_util:get_row_count(View),
    Acc = #mracc{
        db = Db,
        total_rows = Total,
        limit = Args#mrargs.limit,
        skip = Args#mrargs.skip,
        callback = Callback,
        user_acc = UAcc,
        reduce_fun = fun couch_mrview_util:reduce_to_count/1,
        update_seq = View#mrview.update_seq,
        args = Args
    },
    OptList = couch_mrview_util:key_opts(Args),
    {Reds, Acc2} = lists:foldl(
        fun(Opts, {_, Acc0}) ->
            {ok, R, A} = couch_mrview_util:fold(View, fun map_fold/3, Acc0, Opts),
            {R, A}
        end,
        {nil, Acc},
        OptList
    ),
    Offset = couch_mrview_util:reduce_to_count(Reds),
    finish_fold(Acc2, [{total, Total}, {offset, Offset}]).

map_fold(#full_doc_info{} = FullDocInfo, OffsetReds, Acc) ->
    % matches for _all_docs and translates #full_doc_info{} -> KV pair
    case couch_doc:to_doc_info(FullDocInfo) of
        #doc_info{id = Id, revs = [#rev_info{deleted = false, rev = Rev} | _]} = DI ->
            Value = {[{rev, couch_doc:rev_to_str(Rev)}]},
            NS = couch_util:get_value(namespace, Acc#mracc.args#mrargs.extra),
            case Id of
                <<?DESIGN_DOC_PREFIX, _/binary>> when NS =:= <<"_non_design">> -> {ok, Acc};
                _ -> map_fold({{Id, Id}, Value}, OffsetReds, Acc#mracc{doc_info = DI})
            end;
        #doc_info{revs = [#rev_info{deleted = true} | _]} ->
            {ok, Acc}
    end;
map_fold(_KV, _Offset, #mracc{skip = N} = Acc) when N > 0 ->
    {ok, Acc#mracc{skip = N - 1, last_go = ok}};
map_fold(KV, OffsetReds, #mracc{offset = undefined} = Acc) ->
    #mracc{
        total_rows = Total,
        callback = Callback,
        user_acc = UAcc0,
        reduce_fun = Reduce,
        update_seq = UpdateSeq,
        args = Args
    } = Acc,
    Offset = Reduce(OffsetReds),
    Meta = make_meta(Args, UpdateSeq, [{total, Total}, {offset, Offset}]),
    {Go, UAcc1} = Callback(Meta, UAcc0),
    Acc1 = Acc#mracc{meta_sent = true, offset = Offset, user_acc = UAcc1, last_go = Go},
    case Go of
        ok -> map_fold(KV, OffsetReds, Acc1);
        stop -> {stop, Acc1}
    end;
map_fold(_KV, _Offset, #mracc{limit = 0} = Acc) ->
    {stop, Acc};
map_fold({{Key, Id}, Val}, _Offset, Acc) ->
    #mracc{
        db = Db,
        limit = Limit,
        doc_info = DI,
        callback = Callback,
        user_acc = UAcc0,
        args = Args
    } = Acc,
    Doc =
        case DI of
            #doc_info{} -> couch_mrview_util:maybe_load_doc(Db, DI, Args);
            _ -> couch_mrview_util:maybe_load_doc(Db, Id, Val, Args)
        end,
    Row = [{id, Id}, {key, Key}, {value, Val}] ++ Doc,
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{
        limit = Limit - 1,
        doc_info = undefined,
        user_acc = UAcc1,
        last_go = Go
    }};
map_fold(#doc{id = <<"_local/", _/binary>>} = Doc, _Offset, #mracc{} = Acc) ->
    IncludeSys = couch_util:get_value(include_system, Acc#mracc.args#mrargs.extra),

    case should_skip_local_document(IncludeSys, Doc) of
        true ->
            {ok, Acc};
        _ ->
            #mracc{
                limit = Limit,
                callback = Callback,
                user_acc = UAcc0,
                args = Args
            } = Acc,
            #doc{
                id = DocId,
                revs = {Pos, [RevId | _]}
            } = Doc,
            Rev = {Pos, RevId},
            Row =
                [
                    {id, DocId},
                    {key, DocId},
                    {value, {[{rev, couch_doc:rev_to_str(Rev)}]}}
                ] ++
                    if
                        not Args#mrargs.include_docs -> [];
                        true -> [{doc, couch_doc:to_json_obj(Doc, Args#mrargs.doc_options)}]
                    end,
            {Go, UAcc1} = Callback({row, Row}, UAcc0),
            {Go, Acc#mracc{
                limit = Limit - 1,
                reduce_fun = undefined,
                doc_info = undefined,
                user_acc = UAcc1,
                last_go = Go
            }}
    end.

should_skip_local_document(_IncludeSys = false, #doc{
    id = <<"_local/purge-", _/binary>>, body = {Props}
}) ->
    contains_fields([<<"purge_seq">>], Props);
should_skip_local_document(_IncludeSys = false, #doc{
    id = <<"_local/shard-sync", _/binary>>, body = {Props}
}) ->
    contains_fields([<<"target_uuid">>, <<"seq">>], Props);
should_skip_local_document(_IncludeSys, _Doc) ->
    false.

contains_fields([], _Props) ->
    true;
contains_fields([Field | Fields], Props) ->
    case couch_util:get_value(Field, Props) of
        undefined -> false;
        _ -> contains_fields(Fields, Props)
    end.

red_fold(Db, {NthRed, _Lang, View} = RedView, Args, Callback, UAcc) ->
    Finalizer =
        case couch_util:get_value(finalizer, Args#mrargs.extra) of
            undefined ->
                {_, FunSrc} = lists:nth(NthRed, View#mrview.reduce_funs),
                FunSrc;
            CustomFun ->
                CustomFun
        end,
    Acc = #mracc{
        db = Db,
        total_rows = null,
        limit = Args#mrargs.limit,
        skip = Args#mrargs.skip,
        group_level = Args#mrargs.group_level,
        callback = Callback,
        user_acc = UAcc,
        update_seq = View#mrview.update_seq,
        finalizer = Finalizer,
        args = Args
    },
    Grouping = {key_group_level, Args#mrargs.group_level},
    OptList = couch_mrview_util:key_opts(Args, [Grouping]),
    Acc2 = lists:foldl(
        fun(Opts, Acc0) ->
            {ok, Acc1} =
                couch_mrview_util:fold_reduce(RedView, fun red_fold/3, Acc0, Opts),
            Acc1
        end,
        Acc,
        OptList
    ),
    finish_fold(Acc2, []).

red_fold({p, _Partition, Key}, Red, Acc) ->
    red_fold(Key, Red, Acc);
red_fold(_Key, _Red, #mracc{skip = N} = Acc) when N > 0 ->
    {ok, Acc#mracc{skip = N - 1, last_go = ok}};
red_fold(Key, Red, #mracc{meta_sent = false} = Acc) ->
    #mracc{
        args = Args,
        callback = Callback,
        user_acc = UAcc0,
        update_seq = UpdateSeq
    } = Acc,
    Meta = make_meta(Args, UpdateSeq, []),
    {Go, UAcc1} = Callback(Meta, UAcc0),
    Acc1 = Acc#mracc{user_acc = UAcc1, meta_sent = true, last_go = Go},
    case Go of
        ok -> red_fold(Key, Red, Acc1);
        _ -> {Go, Acc1}
    end;
red_fold(_Key, _Red, #mracc{limit = 0} = Acc) ->
    {stop, Acc};
red_fold(_Key, Red, #mracc{group_level = 0} = Acc) ->
    #mracc{
        finalizer = Finalizer,
        limit = Limit,
        callback = Callback,
        user_acc = UAcc0
    } = Acc,
    Row = [{key, null}, {value, maybe_finalize(Red, Finalizer)}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc = UAcc1, limit = Limit - 1, last_go = Go}};
red_fold(Key, Red, #mracc{group_level = exact} = Acc) ->
    #mracc{
        finalizer = Finalizer,
        limit = Limit,
        callback = Callback,
        user_acc = UAcc0
    } = Acc,
    Row = [{key, Key}, {value, maybe_finalize(Red, Finalizer)}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc = UAcc1, limit = Limit - 1, last_go = Go}};
red_fold(K, Red, #mracc{group_level = I} = Acc) when I > 0, is_list(K) ->
    #mracc{
        finalizer = Finalizer,
        limit = Limit,
        callback = Callback,
        user_acc = UAcc0
    } = Acc,
    Row = [{key, lists:sublist(K, I)}, {value, maybe_finalize(Red, Finalizer)}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc = UAcc1, limit = Limit - 1, last_go = Go}};
red_fold(K, Red, #mracc{group_level = I} = Acc) when I > 0 ->
    #mracc{
        finalizer = Finalizer,
        limit = Limit,
        callback = Callback,
        user_acc = UAcc0
    } = Acc,
    Row = [{key, K}, {value, maybe_finalize(Red, Finalizer)}],
    {Go, UAcc1} = Callback({row, Row}, UAcc0),
    {Go, Acc#mracc{user_acc = UAcc1, limit = Limit - 1, last_go = Go}}.

maybe_finalize(Red, null) ->
    Red;
maybe_finalize(Red, RedSrc) ->
    {ok, Finalized} = couch_query_servers:finalize(RedSrc, Red),
    Finalized.

finish_fold(#mracc{last_go = ok, update_seq = UpdateSeq} = Acc, ExtraMeta) ->
    #mracc{callback = Callback, user_acc = UAcc, args = Args} = Acc,
    % Possible send meta info
    Meta = make_meta(Args, UpdateSeq, ExtraMeta),
    {Go, UAcc1} =
        case Acc#mracc.meta_sent of
            false -> Callback(Meta, UAcc);
            _ -> {ok, Acc#mracc.user_acc}
        end,
    % Notify callback that the fold is complete.
    {_, UAcc2} =
        case Go of
            ok -> Callback(complete, UAcc1);
            _ -> {ok, UAcc1}
        end,
    {ok, UAcc2};
finish_fold(#mracc{user_acc = UAcc}, _ExtraMeta) ->
    {ok, UAcc}.

make_meta(Args, UpdateSeq, Base) ->
    case Args#mrargs.update_seq of
        true -> {meta, Base ++ [{update_seq, UpdateSeq}]};
        _ -> {meta, Base}
    end.

get_reduce_fun(#mrargs{extra = Extra}) ->
    case couch_util:get_value(namespace, Extra) of
        <<"_local">> ->
            fun(_) -> null end;
        _ ->
            fun couch_mrview_util:all_docs_reduce_to_count/1
    end.

get_total_rows(Db, #mrargs{extra = Extra}) ->
    case couch_util:get_value(namespace, Extra) of
        <<"_local">> ->
            null;
        <<"_design">> ->
            {ok, N} = couch_db:get_design_doc_count(Db),
            N;
        <<"_non_design">> ->
            {ok, N} = couch_db:get_design_doc_count(Db),
            {ok, Info} = couch_db:get_db_info(Db),
            couch_util:get_value(doc_count, Info) - N;
        _ ->
            {ok, Info} = couch_db:get_db_info(Db),
            couch_util:get_value(doc_count, Info)
    end.

get_update_seq(Db, #mrargs{extra = Extra}) ->
    case couch_util:get_value(namespace, Extra) of
        <<"_local">> ->
            null;
        _ ->
            couch_db:get_update_seq(Db)
    end.

default_cb(complete, Acc) ->
    {ok, lists:reverse(Acc)};
default_cb({final, Info}, []) ->
    {ok, [Info]};
default_cb({final, _}, Acc) ->
    {ok, Acc};
default_cb(ok, Error) when Error == ddoc_updated; Error == insufficient_storage ->
    {ok, Error};
default_cb(Row, Acc) ->
    {ok, [Row | Acc]}.

to_mrargs(KeyList) ->
    lists:foldl(
        fun({Key, Value}, Acc) ->
            Index = lookup_index(couch_util:to_existing_atom(Key)),
            setelement(Index, Acc, Value)
        end,
        #mrargs{extra = [{view_row_map, true}]},
        KeyList
    ).

lookup_index(Key) ->
    Index = lists:zip(
        record_info(fields, mrargs), lists:seq(2, record_info(size, mrargs))
    ),
    couch_util:get_value(Key, Index).
