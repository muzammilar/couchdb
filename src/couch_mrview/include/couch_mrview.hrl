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

-record(mrst, {
    sig=nil,
    fd=nil,
    fd_monitor,
    db_name,
    idx_name,
    language,
    design_opts=[],
    partitioned=false,
    lib,
    views,
    id_btree=nil,
    update_seq=0,
    purge_seq=0,
    first_build,
    partial_resp_pid,
    doc_acc,
    doc_queue,
    write_queue,
    qserver=nil,
    view_info=#{}
}).


-record(mrview, {
    id_num,
    update_seq=0,
    purge_seq=0,
    map_names=[],
    reduce_funs=[],
    def,
    btree=nil,
    options=[]
}).


-record(mrheader, {
    seq=0,
    purge_seq=0,
    id_btree_state=nil,
    view_info=#{}, % replaces log btree in versions < 3.x
    view_states=nil
}).

% Largest 64 bit small int: 2^59-1
-define(MAX_VIEW_LIMIT, 16#7FFFFFFFFFFFFFF).

-record(mrargs, {
    view_type,
    reduce,

    preflight_fun,

    start_key,
    start_key_docid,
    end_key,
    end_key_docid,
    keys,

    direction = fwd,
    limit = ?MAX_VIEW_LIMIT,
    skip = 0,
    group_level = 0,
    group = undefined,
    stable = false,
    update = true,
    multi_get = false,
    inclusive_end = true,
    include_docs = false,
    doc_options = [],
    update_seq=false,
    conflicts,
    callback,
    sorted = true,
    extra = []
}).

-record(vacc, {
    db,
    req,
    resp,
    prepend,
    etag,
    should_close = false,
    buffer = [],
    bufsize = 0,
    threshold = 1490,
    row_sent = false,
    meta_sent = false
}).

-record(lacc, {
    db,
    req,
    resp,
    qserver,
    lname,
    etag,
    code,
    headers
}).
