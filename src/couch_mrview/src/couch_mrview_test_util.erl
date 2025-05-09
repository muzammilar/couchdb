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

-module(couch_mrview_test_util).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("couch/include/couch_db.hrl").
-include_lib("couch/include/couch_eunit.hrl").

init_db(Name, Type) ->
    init_db(Name, Type, 10).

init_db(Name, Type, Count) ->
    {ok, Db} = new_db(Name, Type),
    Docs = make_docs(Type, Count),
    save_docs(Db, Docs).

new_db(Name, Type) when Type == local; Type == design ->
    couch_server:delete(Name, [?ADMIN_CTX]),
    couch_db:create(Name, [?ADMIN_CTX]);
new_db(Name, Type) ->
    couch_server:delete(Name, [?ADMIN_CTX]),
    {ok, Db} = couch_db:create(Name, [?ADMIN_CTX]),
    save_docs(Db, [ddoc(Type)]).

delete_db(Name) ->
    couch_server:delete(Name, [?ADMIN_CTX]).

save_docs(Db, Docs) ->
    {ok, _} = couch_db:update_docs(Db, Docs, []),
    couch_db:reopen(Db).

make_docs(local, Count) ->
    [local_doc(I) || I <- lists:seq(1, Count)];
make_docs(design, Count) ->
    lists:foldl(
        fun(I, Acc) ->
            [doc(I), ddoc(I) | Acc]
        end,
        [],
        lists:seq(1, Count)
    );
make_docs(_, Count) ->
    [doc(I) || I <- lists:seq(1, Count)].

make_docs(_, Since, Count) ->
    [doc(I) || I <- lists:seq(Since, Count)].

ddoc(map) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, <<"_design/bar">>},
            {<<"views">>,
                {[
                    {<<"baz">>,
                        {[
                            {<<"map">>, <<"function(doc) {emit(doc.val, doc.val);}">>}
                        ]}},
                    {<<"bing">>,
                        {[
                            {<<"map">>, <<"function(doc) {}">>}
                        ]}},
                    {<<"zing">>,
                        {[
                            {<<"map">>, <<
                                "function(doc) {\n"
                                "  if(doc.foo !== undefined)\n"
                                "    emit(doc.foo, 0);\n"
                                "}"
                            >>}
                        ]}}
                ]}}
        ]}
    );
ddoc(red) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, <<"_design/red">>},
            {<<"views">>,
                {[
                    {<<"baz">>,
                        {[
                            {<<"map">>, <<
                                "function(doc) {\n"
                                "  emit([doc.val % 2, doc.val], doc.val);\n"
                                "}\n"
                            >>},
                            {<<"reduce">>, <<"function(keys, vals) {return sum(vals);}">>}
                        ]}},
                    {<<"zing">>,
                        {[
                            {<<"map">>, <<
                                "function(doc) {\n"
                                "  if(doc.foo !== undefined)\n"
                                "    emit(doc.foo, null);\n"
                                "}"
                            >>},
                            {<<"reduce">>, <<"_count">>}
                        ]}}
                ]}}
        ]}
    );
ddoc(list) ->
    couch_doc:from_json_obj(
        map_to_proplist(#{
            <<"_id">> => <<"_design/lists">>,
            <<"lists">> => #{
                <<"list">> =>
                    <<
                        "function(head, req){\n"
                        "               send(\"H\");\n"
                        "               var row;\n"
                        "               while(row = getRow()) {send(row.key);}\n"
                        "               return \"T\";\n"
                        "           }"
                    >>
            }
        })
    );
ddoc(Id) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, list_to_binary(io_lib:format("_design/bar~2..0b", [Id]))},
            {<<"views">>, {[]}}
        ]}
    ).

doc(Id) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, list_to_binary(integer_to_list(Id))},
            {<<"val">>, Id}
        ]}
    ).

local_doc(Id) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, list_to_binary(io_lib:format("_local/~b", [Id]))},
            {<<"val">>, Id}
        ]}
    ).

map_to_proplist(#{} = Map) ->
    jiffy:decode(jiffy:encode(Map)).
