%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(user_search_packet).
-author("Order").
-license("MPL-2.0").

-export([decode/2]).

decode(Name, ProtocolVersion) when ProtocolVersion >= 5 ->
    #{ name => datatypes:dec_str(Name) }.