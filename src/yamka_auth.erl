%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(yamka_auth).
-author("Yamka").
-license("MPL-2.0").
-description("Handles access tokens").

-define(TOKEN_TTL, 3600*24*365).

-include("packets/packet.hrl").
-include_lib("cqerl/include/cqerl.hrl").

-export([create_token/2, get_token/1, revoke_agent/1]).
-export([has_permission/1, assert_permission/2]).
-export([totp_secret/0, totp_verify/2]).

%% creates a token
create_token(Permissions, AgentId) ->
    % generate the token and hash it
    TokenBytes = crypto:strong_rand_bytes(48), % 48 bytes fit nicely in 64 base64 chars
    TokenHash  = utils:hash_token(TokenBytes),
    TokenStr   = base64:encode(TokenBytes),
    % write it to the database
    {ok, _} = cqerl:run_query(get(cassandra), #cql_query{
        statement = "INSERT INTO tokens (agent, hash, permissions) VALUES (?,?,?) "
            "USING TTL " ++ integer_to_list(?TOKEN_TTL),
        values    = [
            {agent, AgentId},
            {hash, TokenHash},
            {permissions, [maps:get(C, ?REVERSE_TOKEN_PERMISSION_MAP) || C <- Permissions]}
        ]
    }),
    TokenStr.

%% gets token permissions and owner ID
get_token(Token) ->
    % hash the token
    TokenBytes = base64:decode(Token),
    TokenHash  = utils:hash_token(TokenBytes),
    % perform the query
    {ok, Rows} = cqerl:run_query(get(cassandra), #cql_query{
        statement = "SELECT agent, permissions FROM tokens WHERE hash=?",
        values    = [{hash, TokenHash}]
    }),
    case cqerl:head(Rows) of
        empty_dataset -> invltoken;
        [{agent, Id}, {permissions, Perms}] ->
            {Id, [maps:get(C, ?TOKEN_PERMISSION_MAP) || C <- Perms]}
    end.

revoke_agent(A) ->
    cqerl:run_query(get(cassandra), #cql_query{
        statement = "DELETE FROM tokens WHERE agent=?",
        values    = [{agent, A}]
    }).

%% checks whether the client has a permission flag set
has_permission(Perm) -> lists:member(Perm, get(perms)).

%% "asserts" a permission
assert_permission(Perm, {ScopeRef, Seq}) ->
    {_, true} = {{ScopeRef,
        status_packet:make(permission_denied, "Missing " ++ atom_to_list(Perm) ++ " token permission", Seq)},
        has_permission(Perm)}.

%% creates a TOTP secret
totp_secret() -> pot_base32:encode(crypto:strong_rand_bytes(10)).

%% verifies a TOTP token
totp_verify(Secret, Token) when is_list(Token) -> totp_verify(Secret, list_to_binary(Token));
totp_verify(Secret, Token) -> pot:valid_totp(Token, Secret, [{window, 1}]).