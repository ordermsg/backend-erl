%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(logging).
-behaviour(gen_server).
-author("Order").
-license("MPL-2.0").
-description("Logging gen_server").

-export([start/0, stop/1, start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([dbg/2, log/2, warn/2, err/2]).
-record(state, {level}).

dbg (F, A) -> gen_server:cast(?MODULE, {dbg,  F, A}).
log (F, A) -> gen_server:cast(?MODULE, {log,  F, A}).
warn(F, A) -> gen_server:cast(?MODULE, {warn, F, A}).
err (F, A) -> gen_server:cast(?MODULE, {err,  F, A}).

level_spec(Lvl) -> lists:nth(Lvl + 1, ["DBG", "LOG", "WRN", "ERR"]).
maybe_write(Lvl, Format, Args, #state{level=Tlvl}) ->
    if
        Lvl < Tlvl -> none;
        true ->
            Formatted = lists:flatten(io_lib:format(Format, Args)),
            ToWrite = lists:flatten(io_lib:format("[~p ~p][~s] ~s~n", [
                date(), time(), level_spec(Lvl), Formatted])),
            io:fwrite(ToWrite)
    end.

stop(Name)       -> gen_server:call(Name, stop).
start()          -> start_link(?MODULE).
start_link(Name) -> gen_server:start_link({local, Name}, ?MODULE, [], []).
init(_Args) ->
    {ok, #state{level=1}}.

handle_cast({dbg,  Format, Args}, State) -> maybe_write(0, Format, Args, State), {noreply, State};
handle_cast({log,  Format, Args}, State) -> maybe_write(1, Format, Args, State), {noreply, State};
handle_cast({warn, Format, Args}, State) -> maybe_write(2, Format, Args, State), {noreply, State};
handle_cast({err,  Format, Args}, State) -> maybe_write(3, Format, Args, State), {noreply, State};
handle_cast(_Msg, State)  -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

handle_call(stop, _From, State)     -> {stop, normal, stopped, State};
handle_call(_Request, _From, State) -> {reply, ok, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
