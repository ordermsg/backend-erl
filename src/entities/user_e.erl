%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(user_e).
-author("Order").
-license("MPL-2.0").
-description("The user entity").

-include("entity.hrl").
-include_lib("cqerl/include/cqerl.hrl").

-export([get/1, search/1, update/2, email_in_use/1, create/4, create/3, online/1]).
-export([broadcast_status/1, broadcast_status/2]).
-export([manage_contact/3, opposite_type/1, contact_field/1]).
-export([add_dm_channel/2]).

%% returns true if the user is currently connected
online(Id) -> length(ets:lookup(icpc_processes, Id)) > 0.

%% broadcasts the user's status after they have logged in
broadcast_status(Id) ->
    #{status:=Status} = user_e:get(Id),
    broadcast_status(Id, Status).
broadcast_status(Id, Status) ->
    normal_client:icpc_broadcast_to_aware(#entity{type=user, fields=#{id=>Id, status=>Status}}, [status]).

%% checks if the specified E-Mail address is in use
email_in_use(EMail) ->
    {ok, User} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT email FROM users WHERE email=?",
        values    = [{email, EMail}]
    }),
    cqerl:size(User) > 0.

%% creates the user
create(Name, EMail, Password, BotOwner) ->
    Id = utils:gen_snowflake(),
    % hash the password
    Salt = crypto:strong_rand_bytes(32),
    PasswordHash = utils:hash_password(Password, Salt),
    % execute the CQL query
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "INSERT INTO users (id,name,tag,email,salt,password,status,status_text, "
                    "ava_file,badges,bot_owner,wall,email_confirmed) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,false)",
        values = [
            {id, Id},
            {name, Name},
            {tag, rand:uniform(99999)},
            {email, EMail},
            {salt, Salt},
            {password, PasswordHash},
            {status, 1},
            {status_text, ""},
            % generate a random avatar
            {ava_file, file_storage:register_file(utils:gen_avatar(), "user_avatar.png")},
            {badges, if BotOwner > 0 -> [3]; true -> [] end},
            {bot_owner, BotOwner},
            {wall, channel:create(wall)}
        ]
    }),
    Id.

create(Name, EMail, Password) -> create(Name, EMail, Password, 0).

%% gets a user by ID
get(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT * FROM users WHERE id=?",
        values    = [{id, Id}]
    }),
    1 = cqerl:size(Rows),
    Row = maps:from_list(cqerl:head(Rows)),
    % insert default values
    Vals = maps:merge(#{
        friends     => [],
        blocked     => [],
        pending_in  => [],
        pending_out => [],
        groups      => [],
        badges      => []
    }, maps:filter(fun(_, V) -> V /= null end, Row)),
    % convert the status into its atomic representation
    #{status := StatusNum} = Vals,
    maps:put(status, maps:get(StatusNum, ?USER_STATUS_MAP), Vals).

%% searches a user by name and tag
search(NameTag) ->
    [Name, TagStr] = string:tokens(NameTag, "#"),
    Tag = list_to_integer(TagStr),
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        % ALLOW FILTERING should be fine, we're guaranteed to have <=1k users with the same tag
        statement = "SELECT id FROM users WHERE name=? AND tag=? ALLOW FILTERING",
        values    = [{name, Name}, {tag, Tag}]
    }),
    1 = cqerl:size(Rows),
    [{id, Id}] = cqerl:head(Rows),
    Id.

%% updates a user record
update(Id, Fields) ->
    {Str, Bind} = entity:construct_kv_str(Fields),
    Statement = "UPDATE users SET " ++ Str ++ " WHERE id=?",
    % de-atomize the status field if present
    Vals = [{K, case K of status->maps:get(V, utils:swap_map(?USER_STATUS_MAP));_->V end} || {K,V} <- Bind],
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = Statement,
        values    = [{id, Id}|Vals]
    }).

%% adds a contact
add_contact(Id, {friend, Tid})      -> add_contacts(Id, "friends",     [Tid]);
add_contact(Id, {pending_in, Tid})  -> add_contacts(Id, "pending_in",  [Tid]);
add_contact(Id, {pending_out, Tid}) -> add_contacts(Id, "pending_out", [Tid]);
add_contact(Id, {blocked, Tid})     -> add_contacts(Id, "blocked",     [Tid]);
add_contact(Id, {group, Tid})       -> add_contacts(Id, "groups",      [Tid]);
add_contact(_,  {none, _}) -> ok.
add_contacts(Id, PropName, Tids) ->
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "UPDATE users SET " ++ PropName ++ "+=? WHERE id=?",
        values    = [{id, Id}, {list_to_atom(PropName), Tids}]
    }).

%% removes a contact
remove_contact(Id, {friend, Tid})      -> remove_contacts(Id, "friends",     [Tid]);
remove_contact(Id, {pending_in, Tid})  -> remove_contacts(Id, "pending_in",  [Tid]);
remove_contact(Id, {pending_out, Tid}) -> remove_contacts(Id, "pending_out", [Tid]);
remove_contact(Id, {blocked, Tid})     -> remove_contacts(Id, "blocked",     [Tid]);
remove_contact(Id, {group, Tid})       -> remove_contacts(Id, "groups",      [Tid]);
remove_contact(_,  {none, _}) -> ok.
remove_contacts(Id, PropName, Tids) ->
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "UPDATE users SET " ++ PropName ++ "-=? WHERE id=?",
        values    = [{id, Id}, {list_to_atom(PropName), Tids}]
    }).

%% determines the opposite of the contact type for the target ID
opposite_type(friend)      -> friend;
opposite_type(blocked)     -> none; % (un-)blocking somebody shouldn't change the subject's block list
opposite_type(pending_in)  -> pending_out;
opposite_type(pending_out) -> pending_in;
opposite_type(group)       -> none.

%% determines the field that contains contacts of type
contact_field(friend) -> friends;
contact_field(F)      -> F.

%% adds/removes a contact to/from both the object and the subject
manage_contact(Id, add, {Type, Tid}) ->
    add_contact(Id, {Type, Tid}),
    add_contact(Tid, {opposite_type(Type), Id});

manage_contact(Id, remove, {Type, Tid}) ->
    remove_contact(Id, {Type, Tid}),
    remove_contact(Tid, {opposite_type(Type), Id}).

%% adds/removes a channel
add_dm_channel(Peers=[_,_], Channel) ->
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "INSERT INTO dm_channels (users, channel) VALUES (?, ?)",
        values    = [{users, Peers}, {channel, Channel}]
    }).