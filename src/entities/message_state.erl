%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(message_state).
-author("Order").
-license("MPL-2.0").
-description("The message state entity").

-include("entity.hrl").
-include_lib("cqerl/include/cqerl.hrl").

-export([get/1, create/2, filter_sections/1]).

%% gets a message state by ID
get(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT * FROM message_states WHERE id=?",
        values    = [{id, Id}]
    }),
    1 = cqerl:size(Rows),
    maps:map(fun(K, V) ->
        case K of
            sections -> [#message_section{type=maps:get(Type, ?MESSAGE_SECTION_TYPE_MAP), text=Te, blob=B}
                || [{type, Type}, {txt, Te}, {blob, B}] <- V];
            _ -> V
        end
    end, maps:from_list(cqerl:head(Rows))).

%% creates a message state
create(MsgId, Sections) ->
    Id = utils:gen_snowflake(),
    % execute the CQL query
    {ok, _} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "INSERT INTO message_states (id, msg_id, sections) VALUES (?,?,?)",
        values = [
            {id,       Id},
            {msg_id,   MsgId},
            {sections, [
                [
                    {type, maps:get(Type, ?REVERSE_MESSAGE_SECTION_TYPE_MAP)},
                    {txt,  Text},
                    {blob, Blob}
                ] || #message_section{type=Type, text=Text, blob=Blob} <- Sections]}
        ]
    }),
    Id.

% limit text type sections to 4096 chars
filter_section({T, Text, _}) when T =:= text; T =:= code ->
    #message_section{type=T, text=string:trim(string:slice(Text, 0, 4096), both, "\r\n\t "), blob=0};
filter_section({quote, Text, Q}) ->
    Filtered = filter_section({text, Text, 0}),
    Filtered#message_section{type=quote, blob=Q};
% filter out text in files
filter_section({file, _, F})   -> #message_section{type=file,   text="", blob=F};
% invites are no more than 12 chars long
filter_section({invite, I, _}) -> #message_section{type=invite, text=string:slice(I, 0, 12), blob=0};
% usernames are no more than 96 chars long
filter_section({user, I, _})   -> #message_section{type=user,   text=string:slice(I, 0, 96), blob=0};
% I don't really think your bot needs more than 8k characters for its UI
filter_section({bot_ui, I, _}) -> #message_section{type=bot_ui, text=string:slice(I, 0, 8192), blob=0}.

let_through({T, Text, _B}) when T =/= file -> length(Text) > 0;
let_through({T, _Text, B}) when T =:= file -> B > 0.

filter_sections([]) -> [];
filter_sections([#message_section{type=T, text=Te, blob=B}|Tail]) ->
    Filtered = #message_section{type=FT, text=FTe, blob=FB} = filter_section({T, Te, B}),
    Rest = filter_sections(Tail),
    Let = let_through({FT, FTe, FB}),
    if
        Let -> [Filtered | Rest];
        true -> Rest
    end.