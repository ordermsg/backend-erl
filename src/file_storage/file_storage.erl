%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(file_storage).
-author("Yamka").
-license("MPL-2.0").
-description("File storage manager. Assumes ?STORAGE_PATH points to a distributed NFS like Gluster").

-define(STORAGE_PATH, "/data/brick1/gv0/file_storage/").
-include_lib("cqerl/include/cqerl.hrl").
% http://erlang.org/doc/man/file.html#type-file_info
-record(file_info, {size, type, access, atime, mtime, ctime, mode, links, major_device, minor_device, inode, uid, gid}).

-export([register_file/2, send_file/3, recv_file/3, exists/1]).
-export([max_size/0, max_size_text/0]).

%% determines the file name by its ID
path_in_storage(Id) -> string:concat(?STORAGE_PATH, integer_to_list(Id)).

extract_size(Path) ->
    case file:read_file(Path) of
        % GIF
        {ok, <<"GIF87a", W:16/little, H:16/little, _/bitstring>>} -> {ok, {W, H}};
        {ok, <<"GIF89a", W:16/little, H:16/little, _/bitstring>>} -> {ok, {W, H}};
        % PNG
        {ok, <<137,80,78,71,13,10,26,10, _:32, 73,72,68,82, W:32, H:32, _/bitstring>>} -> {ok, {W, H}};
        {ok, _} -> {error, unknown_format};
        {error, E} -> {error, E}
    end.

parse_image(Path) ->
    case eblurhash:magick(Path) of
        {ok, Preview} ->
            case extract_size(Path) of
                {ok, {W, H}} -> {lists:flatten(io_lib:format("~px~p", [W, H])), Preview};
                {error, SizeErr} -> logging:log("size detection error: ~p", [SizeErr]), {"", Preview}
            end;
        {error, HashErr} -> logging:log("blurhash error: ~p", [HashErr]), {"", ""}
    end.

%% moves a file into the storage path and registers it in the DB
register_file(Path, Name) ->
    % read file info
    {ok, #file_info{size=FileSize}} = file:read_file_info(Path),
    % generate an ID
    Id = utils:gen_snowflake(),
    % try to parse the image (returns {"", ""} if the file is not an image)
    {PixelSize, Preview} = parse_image(Path),
    % move it into the storage under the ID
    {ok, FileSize} = file:copy(Path, path_in_storage(Id)),
    file:delete(Path),
    % store it in the DB
    {ok, _} = cqerl:run_query(get(cassandra), #cql_query{
        statement = "INSERT INTO blob_store (id, name, preview, pixel_size, length) VALUES (?, ?, ?, ?, ?)",
        values    = [
            {id,         Id},
            {name,       Name},
            {preview,    Preview},
            {pixel_size, PixelSize},
            {length,     FileSize}
        ]
    }),
    Id.

%% sends a file to the client
send_file(Id, Reply, Settings) ->
    spawn(file_client, client_init, [Settings, {send_file, path_in_storage(Id), Reply}]).

%% receives a file from the client
recv_file(Reply, Settings, {Length, Name}) ->
    spawn(file_client, client_init, [Settings, {recv_file, Length, Name, Reply}]).

%% checks if a file exists
exists(Id) -> filelib:is_file(path_in_storage(Id)).

max_size() -> 128 * 1024 * 1024.
max_size_text() -> "128 MiB".