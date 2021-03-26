%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(group_e).
-author("Order").
-license("MPL-2.0").
-description("The group entity").

-include_lib("cqerl/include/cqerl.hrl").

-export([get_channels/1, get_roles/1, get/1, create/2]).
-export([get_invites/1, add_invite/1, remove_invite/2, resolve_invite/1]).

get_channels(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT id FROM channels WHERE group=?",
        values    = [{group, Id}]
    }),
    [C || [{id, C}] <- cqerl:all_rows(Rows)].
get_roles(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT id FROM roles WHERE group=?",
        values    = [{group, Id}]
    }),
    [C || [{id, C}] <- cqerl:all_rows(Rows)].
get_invites(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT code FROM invites WHERE group=?",
        values    = [{group, Id}]
    }),
    [C || [{code, C}] <- cqerl:all_rows(Rows)].
get(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT * FROM groups WHERE id=?",
        values    = [{id, Id}]
    }),
    1 = cqerl:size(Rows),
    maps:merge(maps:from_list(cqerl:head(Rows)),
        #{channels => get_channels(Id), roles => get_roles(Id), invites => get_invites(Id)}).

create(Name, Owner) ->
    Id = utils:gen_snowflake(),
    Everyone = role:create(Id, "everyone", 0, 1, 0),
    Icon = file_storage:register_file(utils:gen_avatar(), "group_icon.png"),
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "INSERT INTO groups (id, name, icon, owner, everyone_role) VALUES (?,?,?,?,?)",
        values = [
            {id, Id}, {icon, Icon}, {name, Name}, {owner, Owner},
            {everyone_role, Everyone}
        ]
    }),
    % create a default channel
    channel:create(normal, "Text 1", Id, [], false),
    {Id, Everyone}.

add_invite(Id) ->
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "INSERT INTO invites (group, code) VALUES (?,?)",
        values    = [{group, Id}, {code, utils:gen_invite()}]
    }).
remove_invite(_, Code) ->
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "DELETE FROM invites WHERE code=?",
        values    = [{code, Code}]
    }).
resolve_invite(Code) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT group FROM invites WHERE code=?",
        values    = [{code, Code}]
    }),
    case cqerl:head(Rows) of
        empty_dataset -> error;
        [{group, Id}] -> {ok, Id}
    end.