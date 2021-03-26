%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(entity_get_packet).
-author("Order").
-license("MPL-2.0").

-include("../entities/entity.hrl").
-export([decode/2]).

len_segment(Bin) ->
    <<_:78, C:1/unsigned, P:1/unsigned, _/binary>> = Bin,
    10 + if C > 0, P > 0 -> 9 + 11;
            C > 0        -> 9;
            P > 0        -> 11;
            true         -> 0
    end.

-spec decode_pagination(binary()) -> #entity_pagination{}.
decode_pagination(PC) ->
    <<Field:8/unsigned-integer, Dir:8/unsigned-integer, From:64/unsigned-integer, Cnt:8/unsigned-integer>> = PC,
    DirAtom = case Dir of
        0 -> down;
        1 -> up
    end,
    #entity_pagination{field=Field, dir=DirAtom, from=From, cnt=Cnt}.
decode_context(PC) ->
    <<Type:8/unsigned-integer, Id:64/unsigned-integer>> = PC,
    #entity_context{type=maps:get(Type, ?ENTITY_TYPE_MAP), id=Id}.

decode_segment(Bin) ->
    <<Type:8/unsigned-integer, Id:64/unsigned-integer, _:6, C:1/unsigned-integer, P:1/unsigned-integer, PC/binary>> = Bin,
    {Pagination, PC_Rest} = case P of
        0 -> {none, PC};
        1 -> <<P_Bin:88/bitstring, Rest/bitstring>> = PC,
            {decode_pagination(P_Bin), Rest}
    end,
    Context = case C of
        0 -> none;
        1 -> decode_context(binary:part(PC_Rest, 0, 9))
    end,
    #entity_get_rq{type=maps:get(Type, ?ENTITY_TYPE_MAP), id=Id, pagination=Pagination, context=Context}.

decode(P, Proto) when Proto >= 5 ->
    #{entities => datatypes:dec_list(P, fun decode_segment/1, fun len_segment/1, 2)}.