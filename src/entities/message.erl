%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(message).
-author("Order").
-license("MPL-2.0").
-description("The message entity").

-include_lib("cqerl/include/cqerl.hrl").

-export([get/1, create/2, delete/1]).
-export([get_states/1, get_latest_state/1]).

%% gets a message by ID
get(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT * FROM messages WHERE id=?",
        values    = [{id, Id}]
    }),
    1 = cqerl:size(Rows),
    maps:from_list(cqerl:head(Rows)).

%% creates a message
create(Channel, Sender) ->
    Id = utils:gen_snowflake(),
    % get the channel LCID
    #{lcid := Lcid} = channel:get(Channel),
    % execute the CQL query
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "INSERT INTO messages (id, channel, lcid, sender) VALUES (?,?,?,?)",
        values = [
            {id,      Id},
            {channel, Channel},
            {lcid,    Lcid + 1},
            {sender,  Sender}
        ]
    }),
    % update the channel's LCID
    channel:update(Channel, #{lcid => Lcid + 1}),
    Id.

delete(Id) ->
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "DELETE FROM messages WHERE id=?",
        values = [{id, Id}]
    }).

%% gets all message states
get_latest_state(Id) -> lists:last(get_states(Id)).
get_states(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT id FROM message_states WHERE msg_id=?",
        values = [
            {msg_id, Id}
        ]
    }),
    % we can't instruct Cassandra with neither ORDER BY nor CLUSTERING ORDER BY, unfortunately
    % fortunately, though, we can guarantee it's not bigger than 50 elements anyways
    lists:sort([S || [{id, S}] <- cqerl:all_rows(Rows)]).