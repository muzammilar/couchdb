.. Licensed under the Apache License, Version 2.0 (the "License"); you may not
.. use this file except in compliance with the License. You may obtain a copy of
.. the License at
..
..   http://www.apache.org/licenses/LICENSE-2.0
..
.. Unless required by applicable law or agreed to in writing, software
.. distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
.. WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
.. License for the specific language governing permissions and limitations under
.. the License.

.. _api/db:

=========
``/{db}``
=========

.. http:head:: /{db}
    :synopsis: Checks the database existence

    Returns the HTTP Headers containing a minimal amount of information
    about the specified database. Since the response body is empty, using the
    HEAD method is a lightweight way to check if the database exists already or
    not.

    :param db: Database name
    :code 200: Database exists
    :code 404: Requested database not found

    **Request**:

    .. code-block:: http

        HEAD /test HTTP/1.1
        Host: localhost:5984

    **Response**:

    .. code-block:: http

        HTTP/1.1 200 OK
        Cache-Control: must-revalidate
        Content-Type: application/json
        Date: Mon, 12 Aug 2013 01:27:41 GMT
        Server: CouchDB (Erlang/OTP)

.. http:get:: /{db}
    :synopsis: Returns the database information

    Gets information about the specified database.

    :param db: Database name
    :<header Accept: - :mimetype:`application/json`
                     - :mimetype:`text/plain`
    :>header Content-Type: - :mimetype:`application/json`
                           - :mimetype:`text/plain; charset=utf-8`
    :>json number cluster.n: Replicas. The number of copies of every document.
    :>json number cluster.q: Shards. The number of range partitions.
    :>json number cluster.r: Read quorum. The number of consistent copies
      of a document that need to be read before a successful reply.
    :>json number cluster.w: Write quorum. The number of copies of a document
      that need to be written before a successful reply.
    :>json boolean compact_running: Set to ``true`` if the database compaction
      routine is operating on this database.
    :>json string db_name: The name of the database.
    :>json number disk_format_version: The version of the physical format used
      for the data when it is stored on disk.
    :>json number doc_count: A count of the documents in the specified
      database.
    :>json number doc_del_count: Number of deleted documents
    :>json string instance_start_time: Always ``"0"``. (Returned for legacy
      reasons.)
    :>json string purge_seq: An opaque string that describes the purge state
      of the database. Do not rely on this string for counting the number
      of purge operations.
    :>json number sizes.active: The size of live data inside the database, in
      bytes.
    :>json number sizes.external: The uncompressed size of database contents
      in bytes.
    :>json number sizes.file: The size of the database file on disk in bytes.
      Views indexes are not included in the calculation.
    :>json string update_seq: An opaque string that describes the state
      of the database. Do not rely on this string for counting the number
      of updates.
    :>json boolean props.partitioned: (optional) If present and true, this
      indicates that the database is partitioned.
    :code 200: Request completed successfully
    :code 401: Unauthorized request to a protected API
    :code 403: Insufficient permissions / :ref:`Too many requests with invalid credentials<error/403>`
    :code 404: Requested database not found

    **Request**:

    .. code-block:: http

        GET /receipts HTTP/1.1
        Accept: application/json
        Host: localhost:5984

    **Response**:

    .. code-block:: http

        HTTP/1.1 200 OK
        Cache-Control: must-revalidate
        Content-Length: 258
        Content-Type: application/json
        Date: Mon, 12 Aug 2013 01:38:57 GMT
        Server: CouchDB (Erlang/OTP)

        {
            "cluster": {
                "n": 3,
                "q": 8,
                "r": 2,
                "w": 2
            },
            "compact_running": false,
            "db_name": "receipts",
            "disk_format_version": 6,
            "doc_count": 6146,
            "doc_del_count": 64637,
            "instance_start_time": "0",
            "props": {},
            "purge_seq": 0,
            "sizes": {
                "active": 65031503,
                "external": 66982448,
                "file": 137433211
            },
            "update_seq": "292786-g1AAAAF..."
        }

.. http:put:: /{db}
    :synopsis: Creates a new database

    Creates a new database. The database name ``{db}`` must be composed by
    following next rules:

    -  Name must begin with a lowercase letter (``a-z``)

    -  Lowercase characters (``a-z``)

    -  Digits (``0-9``)

    -  Any of the characters ``_``, ``$``, ``(``, ``)``, ``+``, ``-``, and
       ``/``.

    If you're familiar with `Regular Expressions`_, the rules above could be
    written as ``^[a-z][a-z0-9_$()+/-]*$``.

    :param db: Database name
    :query integer q: Shards, aka the number of range partitions. Default is
      2, unless overridden in the :config:option:`cluster config <cluster/q>`.
    :query integer n: Replicas. The number of copies of the database in the
      cluster. The default is 3, unless overridden in the
      :config:option:`cluster config <cluster/n>` .
    :query boolean partitioned: Whether to create a partitioned database.
      Default is false.
    :<header Accept: - :mimetype:`application/json`
                     - :mimetype:`text/plain`
    :>header Content-Type: - :mimetype:`application/json`
                           - :mimetype:`text/plain; charset=utf-8`
    :>header Location: Database URI location
    :>json boolean ok: Operation status. Available in case of success
    :>json string error: Error type. Available if response code is ``4xx``
    :>json string reason: Error description. Available if response code is
      ``4xx``
    :code 201: Database created successfully (quorum is met)
    :code 202: Accepted (at least by one node)
    :code 400: Invalid database name
    :code 401: CouchDB Server Administrator privileges required
    :code 403: Insufficient permissions / :ref:`Too many requests with invalid credentials<error/403>`
    :code 412: Database already exists

    **Request**:

    .. code-block:: http

        PUT /db HTTP/1.1
        Accept: application/json
        Host: localhost:5984

    **Response**:

    .. code-block:: http

        HTTP/1.1 201 Created
        Cache-Control: must-revalidate
        Content-Length: 12
        Content-Type: application/json
        Date: Mon, 12 Aug 2013 08:01:45 GMT
        Location: http://localhost:5984/db
        Server: CouchDB (Erlang/OTP)

        {
            "ok": true
        }

    If we repeat the same request to CouchDB, it will response with :code:`412`
    since the database already exists:

    **Request**:

    .. code-block:: http

        PUT /db HTTP/1.1
        Accept: application/json
        Host: localhost:5984

    **Response**:

    .. code-block:: http

        HTTP/1.1 412 Precondition Failed
        Cache-Control: must-revalidate
        Content-Length: 95
        Content-Type: application/json
        Date: Mon, 12 Aug 2013 08:01:16 GMT
        Server: CouchDB (Erlang/OTP)

        {
            "error": "file_exists",
            "reason": "The database could not be created, the file already exists."
        }

    If an invalid database name is supplied, CouchDB returns response with
    :code:`400`:

    **Request**:

    .. code-block:: http

        PUT /_db HTTP/1.1
        Accept: application/json
        Host: localhost:5984

    **Request**:

    .. code-block:: http

        HTTP/1.1 400 Bad Request
        Cache-Control: must-revalidate
        Content-Length: 194
        Content-Type: application/json
        Date: Mon, 12 Aug 2013 08:02:10 GMT
        Server: CouchDB (Erlang/OTP)

        {
            "error": "illegal_database_name",
            "reason": "Name: '_db'. Only lowercase characters (a-z), digits (0-9), and any of the characters _, $, (, ), +, -, and / are allowed. Must begin with a letter."
        }

.. http:delete:: /{db}
    :synopsis: Deletes an existing database

    Deletes the specified database, and all the documents and attachments
    contained within it.

    .. note::
        To avoid deleting a database, CouchDB will respond with the HTTP status
        code 400 when the request URL includes a ?rev= parameter. This suggests
        that one wants to delete a document but forgot to add the document id
        to the URL.

    :param db: Database name
    :<header Accept: - :mimetype:`application/json`
                     - :mimetype:`text/plain`
    :>header Content-Type: - :mimetype:`application/json`
                           - :mimetype:`text/plain; charset=utf-8`
    :>json boolean ok: Operation status
    :code 200: Database removed successfully (quorum is met and database is deleted by at least one node)
    :code 202: Accepted (deleted by at least one of the nodes, quorum is not met yet)
    :code 400: Invalid database name or forgotten document id by accident
    :code 401: CouchDB Server Administrator privileges required
    :code 403: Insufficient permissions / :ref:`Too many requests with invalid credentials<error/403>`
    :code 404: Database doesn't exist or invalid database name

    **Request**:

    .. code-block:: http

        DELETE /db HTTP/1.1
        Accept: application/json
        Host: localhost:5984

    **Response**:

    .. code-block:: http

        HTTP/1.1 200 OK
        Cache-Control: must-revalidate
        Content-Length: 12
        Content-Type: application/json
        Date: Mon, 12 Aug 2013 08:54:00 GMT
        Server: CouchDB (Erlang/OTP)

        {
            "ok": true
        }

.. http:post:: /{db}
    :synopsis: Creates a new document with generated ID if _id is not specified

    Creates a new document in the specified database, using the supplied JSON
    document structure.

    If the JSON structure includes the ``_id`` field, then the document will be
    created with the specified document ID.

    If the ``_id`` field is not specified, a new unique ID will be generated,
    following whatever UUID algorithm is configured for that server.

    :param db: Database name
    :<header Accept: - :mimetype:`application/json`
                     - :mimetype:`text/plain`
    :<header Content-Type: :mimetype:`application/json`

    :query string batch: Stores document in :ref:`batch mode
      <api/doc/batch-writes>` Possible values: ``ok``. *Optional*

    :>header Content-Type: - :mimetype:`application/json`
                           - :mimetype:`text/plain; charset=utf-8`
    :>header Location: Document's URI

    :>json string id: Document ID
    :>json boolean ok: Operation status
    :>json string rev: Revision info

    :code 201: Document created and stored on disk
    :code 202: Document data accepted, but not yet stored on disk
    :code 400: Invalid database name
    :code 401: Write privileges required
    :code 403: Insufficient permissions / :ref:`Too many requests with invalid credentials<error/403>`
    :code 404: Database doesn't exist
    :code 409: A Conflicting Document with same ID already exists

    **Request**:

    .. code-block:: http

        POST /db HTTP/1.1
        Accept: application/json
        Content-Length: 81
        Content-Type: application/json

        {
            "servings": 4,
            "subtitle": "Delicious with fresh bread",
            "title": "Fish Stew"
        }

    **Response**:

    .. code-block:: http

        HTTP/1.1 201 Created
        Cache-Control: must-revalidate
        Content-Length: 95
        Content-Type: application/json
        Date: Tue, 13 Aug 2013 15:19:25 GMT
        Location: http://localhost:5984/db/ab39fe0993049b84cfa81acd6ebad09d
        Server: CouchDB (Erlang/OTP)

        {
            "id": "ab39fe0993049b84cfa81acd6ebad09d",
            "ok": true,
            "rev": "1-9c65296036141e575d32ba9c034dd3ee"
        }

Specifying the Document ID
==========================

The document ID can be specified by including the ``_id`` field in the
JSON of the submitted record. The following request will create the same
document with the ID ``FishStew``.

    **Request**:

    .. code-block:: http

        POST /db HTTP/1.1
        Accept: application/json
        Content-Length: 98
        Content-Type: application/json

        {
            "_id": "FishStew",
            "servings": 4,
            "subtitle": "Delicious with fresh bread",
            "title": "Fish Stew"
        }

    **Response**:

    .. code-block:: http

        HTTP/1.1 201 Created
        Cache-Control: must-revalidate
        Content-Length: 71
        Content-Type: application/json
        Date: Tue, 13 Aug 2013 15:19:25 GMT
        ETag: "1-9c65296036141e575d32ba9c034dd3ee"
        Location: http://localhost:5984/db/FishStew
        Server: CouchDB (Erlang/OTP)

        {
            "id": "FishStew",
            "ok": true,
            "rev": "1-9c65296036141e575d32ba9c034dd3ee"
        }

.. _api/doc/batch-writes:

Batch Mode Writes
=================

You can write documents to the database at a higher rate by using the batch
option. This collects document writes together in memory (on a per-user basis)
before they are committed to disk. This increases the risk of the documents not
being stored in the event of a failure, since the documents are not written to
disk immediately.

Batch mode is not suitable for critical data, but may be ideal for applications
such as log data, when the risk of some data loss due to a crash is acceptable.

To use batch mode, append the ``batch=ok`` query argument to the URL of a
:post:`/{db}`, :put:`/{db}/{docid}`, or :delete:`/{db}/{docid}` request. The
CouchDB server will respond with an HTTP :statuscode:`202` response code
immediately.

.. note::
    Creating or updating documents with batch mode doesn't guarantee that all
    documents will be successfully stored on disk. For example, individual
    documents may not be saved due to conflicts, rejection by
    :ref:`validation function <vdufun>` or by other reasons, even if overall
    the batch was successfully submitted.

**Request**:

.. code-block:: http

    POST /db?batch=ok HTTP/1.1
    Accept: application/json
    Content-Length: 98
    Content-Type: application/json

    {
        "_id": "FishStew",
        "servings": 4,
        "subtitle": "Delicious with fresh bread",
        "title": "Fish Stew"
    }

**Response**:

.. code-block:: http

    HTTP/1.1 202 Accepted
    Cache-Control: must-revalidate
    Content-Length: 28
    Content-Type: application/json
    Date: Tue, 13 Aug 2013 15:19:25 GMT
    Location: http://localhost:5984/db/FishStew
    Server: CouchDB (Erlang/OTP)

    {
        "id": "FishStew",
        "ok": true
    }

.. _Regular Expressions: http://en.wikipedia.org/wiki/Regular_expression
