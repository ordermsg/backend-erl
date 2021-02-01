-module(file_e). % the _e is here because the "file" exists in OTP
-author("Order").
-license("MPL-2.0").
-description("The file entity").

-include("entity.hrl").
-include("../packets/packet.hrl").
-include_lib("cqerl/include/cqerl.hrl").

-export([get/1]).

%% gets a file by ID
get(Id) ->
    {ok, Rows} = cqerl:run_query(erlang:get(cassandra), #cql_query{
        statement = "SELECT * FROM blob_store WHERE id=?",
        values    = [{id, Id}]
    }),
    1 = cqerl:size(Rows),
    Row = maps:from_list(cqerl:head(Rows)),
    Row.