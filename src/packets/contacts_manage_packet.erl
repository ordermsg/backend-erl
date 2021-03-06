%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(contacts_manage_packet).
-author("Yamka").
-license("MPL-2.0").

-include("packet.hrl").
-export([decode/2]).

decode(<<Type:8/unsigned,
         Action:8/unsigned,
         Id:64/unsigned>>, Proto) when Proto >= 5 ->
    #{
        type   => maps:get(Type, #{0=>friend,1=>blocked,2=>pending_in,3=>pending_out,4=>group}),
        action => maps:get(Action, #{0=>add,1=>remove}),
        id     => Id
    }.