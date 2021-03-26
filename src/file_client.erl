%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(file_client).
-author("Order").
-license("MPL-2.0").
-description("File process. Sends and receives files. Depends on a \"normal client\" process. In fact, it's using").

-define(CHUNK_SIZE, 1024*10). % bytes
-include("entities/entity.hrl").
-include_lib("cqerl/include/cqerl.hrl").

-export([client_init/2]).

recv_chunk(Handle, Length) ->
    receive
        <<DataChunk/binary>> ->
            Trimmed = binary:part(DataChunk, 0, min(Length, byte_size(DataChunk))),
            ChunkLen = byte_size(Trimmed),
            logging:dbg("client file transfer: ~p/~p", [ChunkLen, Length]),
            file:write(Handle, Trimmed),
            if
                ChunkLen >= Length -> ok;
                true -> recv_chunk(Handle, Length - ChunkLen)
            end;

        _ -> recv_chunk(Handle, Length)
    end.

send_chunk(Handle, Position, Reply) ->
    {ok, Data} = file:read(Handle, ?CHUNK_SIZE),
    send_packet(file_data_chunk_packet:make(Position, Data, Reply)),
    case byte_size(Data) of
        ?CHUNK_SIZE -> send_chunk(Handle, Position + byte_size(Data), Reply);
        _ -> send_packet(status_packet:make(stream_end, "File transfer finished", Reply))
    end.

%% sends a file
client_init({Socket, Protocol}, {send_file, Path, Reply}) ->
    put(socket, Socket), put(protocol, Protocol),

    {ok, Handle} = file:open(Path, [read, binary]),
    send_chunk(Handle, 0, Reply),

    exit(normal);

%% receives a file
client_init({Socket, Protocol, Host, Cassandra}, {recv_file, Length, Name, Reply}) ->
    put(socket, Socket), put(protocol, Protocol), put(cassandra, Cassandra),

    send_packet(status_packet:make(start_uploading, "Start uploading", Reply)),

    Path = utils:temp_file_name(),
    {ok, Handle} = file:open(Path, [write, binary]),
    recv_chunk(Handle, Length),
    Id = file_storage:register_file(Path, Name),
    send_packet(entities_packet:make([#entity{type=file, fields=file_e:get(Id)}], Reply)),

    Host ! upload_fin,
    exit(normal).

%% sends a packet
send_packet(P) ->
    logging:dbg("<--F ~p", [packet_iface:clear_for_printing(P)]),
    spawn_monitor(packet_iface, writer, [
        get(socket), P,
        get(protocol), false, self()
    ]),
    receive
        _ -> ok
    end.