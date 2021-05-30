%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-module(entity).
-author("Yamka").
-license("MPL-2.0").

-include("../packets/packet.hrl").
-include("entity.hrl").

-export([handle_get_request/2, handle_entity/3]).
-export([encode_field/2, encode/2, len_decode/2]).
-export([construct_kv_str/1, filter/2]).

structure(Proto, EntityType) ->
    #{Proto := #{EntityType := Structure}} = ?ENTITY_STRUCTURE,
    Structure.

%% updates a user
handle_entity(#entity{type=user, fields=#{id:=Id} = F}, Seq, Ref) ->
    % a user can only change info about themselves
    yamka_auth:assert_permission(edit_profile, {Ref, Seq}),
    {_, Id} = {{Ref, status_packet:make(invalid_id, "You can only change info about yourself", Seq)}, get(id)},
    % only allow allowed fields (wow thx captain obvious)
    BroadcastFields = [name, status, status_text, ava_file],
    AllowedFields = maps:filter(fun(K, _) -> lists:member(K, [email|BroadcastFields]) end, F),
    case maps:size(AllowedFields) of
        0 -> ok;
        _ ->
            % change the DB record
            user_e:update(Id, AllowedFields),
            % broadcast the changes
            Entity = #entity{type=user, fields=maps:merge(AllowedFields, #{id=>Id})},
            normal_client:icpc_broadcast_to_aware(Entity, BroadcastFields)
    end,
    % if the email was changed, un-confirm it and send a confirmation request to the user
    EmailChanged = maps:is_key(email, F),
    if
        EmailChanged ->
            Email = maps:get(email, F),
            user_e:update(Id, #{email => Email, email_confirmed => false}),
            user_e:start_email_confirmation(Id, Email),
            NewEntity = #entity{type=user, fields=#{
                id => Id,
                email => Email,
                email_confirmed => false}},
            normal_client:icpc_broadcast_entity(Id, NewEntity);
        true -> ok
    end,
    % if the agent list was changed, calculate the diff and yank the removed ones
    % (along with their access tokens!)
    AgentsChanged = maps:is_key(agents, F),
    if
        AgentsChanged ->
            OldAgents = agent_e:get_by_user(Id),
            {_, RemovedAgents} = utils:list_diff(maps:get(agents, F), OldAgents),
            [agent_e:delete(A)          || A <- RemovedAgents],
            [yamka_auth:revoke_agent(A) || A <- RemovedAgents],
            % construct the updated list of agents
            NewAgents = lists:foldl(fun(A, Acc) -> case
                lists:member(A, RemovedAgents) of true -> Acc;
                _ -> [A|Acc] end
            end, [], OldAgents),
            case RemovedAgents of
                [] -> ok;
                _ -> normal_client:icpc_broadcast_entity(Id, #entity{type=user,
                    fields=#{id => Id, agents => NewAgents}}, [agents])
            end;
        true -> ok
    end,
    % if the 2FA setting was changed, update auth settings
    MfaChanged = maps:is_key(mfa_enabled, F),
    if
        MfaChanged ->
            MfaEnabled = maps:get(mfa_enabled, F),
            normal_client:icpc_broadcast_entity(Id, #entity{type=user,
                fields=#{id => Id, mfa_enabled => MfaEnabled}}, [mfa_enabled]),
            if
                MfaEnabled ->
                    Secret = yamka_auth:totp_secret(),
                    user_e:update(Id, #{mfa_secret => Secret}),
                    mfa_secret_packet:make(Secret, Seq);
                true ->
                    user_e:update(Id, #{mfa_secret => null}),
                    none
            end;
        true ->
            none
    end;


%% puts a file
handle_entity(#entity{type=file, fields=#{name:=Name, length:=Length}}, Seq, Ref) ->
    {_, none} = {{Ref, status_packet:make(one_upload_only,
            "Only one concurrent upload is allowed", Seq)}, get(file_recv_pid)},
    put(file_recv_pid, file_storage:recv_file(Seq,
        {get(socket), get(protocol), self(), get(cassandra)},
        {Length, Name})),
    none;

%% (re-)sets the typing status
handle_entity(#entity{type=channel, fields=#{id:=Id, typing:=[0]}}, _Seq, _Ref) ->
    channel_e:set_typing(Id, get(id)),
    normal_client:icpc_broadcast_to_aware(chan_awareness,
        #entity{type=channel, fields=#{id=>Id, typing=>channel_e:get_typing(Id)}}, [id, typing]),
    none;
handle_entity(#entity{type=channel, fields=#{id:=Id, typing:=[]}}, _Seq, _Ref) ->
    channel_e:reset_typing(Id, get(id)), 
    normal_client:icpc_broadcast_to_aware(chan_awareness,
        #entity{type=channel, fields=#{id=>Id, typing=>channel_e:get_typing(Id)}}, [id, typing]),
    none;


%% sets the unread message
handle_entity(#entity{type=channel, fields=#{id:=Id, first_unread:=FirstUnread}}, _Seq, _Ref) ->
    % get the message and its LCID
    #{lcid := Lcid} = message_e:get(FirstUnread),
    channel_e:set_unread(Id, get(id), {Lcid, FirstUnread}),
    none;
%% marks the channel as read
handle_entity(#entity{type=channel, fields=#{id:=Id, unread:=0}}, _Seq, _Ref) ->
    % get the last message and its LCID
    case channel_e:get_messages(Id, 9223372036854775807, 1, down) of
        [] -> ok;
        [LastMsg] ->
            #{lcid := Lcid} = message_e:get(LastMsg),
            channel_e:set_unread(Id, get(id), {Lcid, LastMsg}),
            channel_e:forget_mentions(Id, get(id))
    end,
    none;


%% creates a channel
handle_entity(#entity{type=channel, fields=#{id:=0, group:=Group, name:=Name}}, Seq, Ref) ->
    yamka_auth:assert_permission(edit_groups, {Ref, Seq}),
    group_e:assert_permission(Group, edit_channels, {Ref, Seq}),

    channel_e:create(Name, Group, [], false),
    normal_client:icpc_broadcast_to_aware(group_awareness, #entity{
        type=group, fields=group_e:get(Group)}, [id, channels]),
    none;


%% deletes a channel
handle_entity(#entity{type=channel, fields=#{id:=Id, group:=0}}, Seq, Ref) ->
    yamka_auth:assert_permission(edit_groups, {Ref, Seq}),
    #{group := Group} = channel_e:get(Id),
    group_e:assert_permission(Group, edit_channels, {Ref, Seq}),

    channel_e:delete(Id),
    normal_client:icpc_broadcast_to_aware(group_awareness, #entity{
        type=group, fields=group_e:get(Group)}, [id, channels]),
    none;


%% modifies a channel
handle_entity(#entity{type=channel, fields=Fields=#{id:=Id}}, Seq, Ref) ->
    yamka_auth:assert_permission(edit_groups, {Ref, Seq}),
    #{group := Group} = channel_e:get(Id),
    group_e:assert_permission(Group, edit_channels, {Ref, Seq}),
    
    channel_e:update(Id, maps:filter(fun(K, _) -> K =/= id end, Fields)),
    normal_client:icpc_broadcast_to_aware(chan_awareness,
        #entity{type=channel, fields=Fields}, maps:keys(Fields)),
    none;


%% sends a message
handle_entity(M=#entity{type=message,       fields=#{id:=0, channel:=Channel, latest:=
              L=#entity{type=message_state, fields=#{id:=0, sections:=Sections}}}}, Seq, Ref) ->
    % check token permissions
    #{group := Group} = channel_e:get(Channel),
    yamka_auth:assert_permission(if
        Group =/= 0 ->
            group_e:assert_permission(Group, send_messages, {Ref, Seq}),
            send_group_messages;
        true -> send_direct_messages
    end, {Ref, Seq}),

    % parse mentions
    Filtered = message_state_e:filter_sections(Sections),
    Mentions = message_state_e:parse_mentions(Filtered),
    % create entities
    {MsgId, _} = message_e:create(Channel, get(id)),
    StateId = message_state_e:create(MsgId, Filtered),
    channel_e:reg_msg(Channel, MsgId),
    % register mentions
    [channel_e:add_mention(Channel, User, MsgId) || User <- Mentions],
    % broadcast the message
    normal_client:icpc_broadcast_to_aware(chan_awareness, Channel,
        M#entity{fields=maps:merge(message_e:get(MsgId), #{states => message_e:get_states(MsgId), latest =>
            L#entity{fields=message_state_e:get(StateId)}})}, [id, states, channel, sender, latest]),
    none;


%% edits a message
handle_entity(M=#entity{type=message,       fields=#{id:=Id, latest:=
              L=#entity{type=message_state, fields=#{id:=0, sections:=Sections}}}}, Seq, Ref) ->
    Existing = message_e:get(Id),
    SelfSent = maps:get(sender, Existing) =:= get(id),
    {_, true} = {{Ref, status_packet:make(permission_denied, "This message was sent by another user", Seq)},
        SelfSent},

    StateId = message_state_e:create(Id, message_state_e:filter_sections(Sections)),
    normal_client:icpc_broadcast_to_aware(chan_awareness, maps:get(channel, Existing),
        M#entity{fields=maps:merge(message_e:get(Id), #{states => message_e:get_states(Id), latest =>
            L#entity{fields=message_state_e:get(StateId)}})}, [id, states, channel, sender, latest]),
    none;


%% deletes a message
handle_entity(M=#entity{type=message, fields=#{id:=Id, sender:=0}}, Seq, Ref) ->
    #{channel := Channel, sender := Sender} = message_e:get(Id),
    #{group := Group} = channel_e:get(Channel),
    {_, true} = {{Ref, status_packet:make(permission_denied, "This message was sent by another user", Seq)},
        Sender =:= get(id)},
    #{group := Group} = channel_e:get(Channel),
    yamka_auth:assert_permission(if
        Group =/= 0 ->
            group_e:assert_permission(Group, delete_others_messages, {Ref, Seq}),
            delete_group_messages;
        true -> delete_direct_messages
    end, {Ref, Seq}),

    channel_e:unreg_msg(Channel, Id),
    message_e:delete(Id),
    normal_client:icpc_broadcast_to_aware(chan_awareness, Channel,
        M#entity{fields=#{id => Id, channel => Channel, sender => 0}},
            [id, channel, sender]),
    none;


%% creates a group
handle_entity(#entity{type=group, fields=#{id:=0, name:=Name}}, Seq, Ref) ->
    yamka_auth:assert_permission(create_groups, {Ref, Seq}),
    #{name := Username} = user_e:get(get(id)),
    {Id, Everyone} = group_e:create(Name, get(id)),
    role_e:add(Everyone, get(id)),
    group_e:cache_user_name(Id, get(id), Username),
    user_e:manage_contact(get(id), add, {group, Id}),
    normal_client:icpc_broadcast_entity(get(id),
        #entity{type=user, fields=user_e:get(get(id))}, [groups]),
    none;


%% deletes a group
handle_entity(#entity{type=group, fields=#{id:=Id, owner:=0}}, Seq, Ref) ->
    yamka_auth:assert_permission(delete_groups, {Ref, Seq}),
    #{owner := Owner,
      channels := Channels,
      roles := Roles,
      invites := Invites,
      everyone_role := Everyone} = group_e:get(Id),
    {_, Owner} = {{Ref, status_packet:make(permission_denied, "Only the owner can do this", Seq)}, get(id)},

    lists:foreach(fun(R) -> group_e:remove_invite(Id, R) end, Invites),
    group_e:delete(Id),
    lists:foreach(fun channel_e:delete/1, Channels),
    lists:foreach(fun role_e:nuke/1, lists:delete(Everyone, Roles)),
    role_e:nuke(Everyone, true),
    normal_client:icpc_broadcast_to_aware(group_awareness,
        #entity{type=group, fields=#{id => Id, owner => 0}}, [id, owner]),
    none;


%% manages invites
handle_entity(#entity{type=group, fields=#{id:=Id, invites:=Invites}}, Seq, Ref) ->
    yamka_auth:assert_permission(edit_groups, {Ref, Seq}),
    group_e:assert_permission(Id, edit_invites, {Ref, Seq}),

    #{invites := ExInvites} = group_e:get(Id),
    {Added, Removed} = utils:list_diff(Invites, ExInvites),
    lists:foreach(fun(_) -> group_e:add_invite(Id) end, lists:seq(1, length(Added))),
    lists:foreach(fun(I) -> group_e:remove_invite(Id, I) end, Removed),
    #{invites := NewInvites} = group_e:get(Id),
    entities_packet:make([#entity{type=group, fields=#{id => Id, invites => NewInvites}}], Seq);


%% creates a poll
handle_entity(#entity{type=poll, fields=#{id:=0, options:=Options}}, Seq, Ref) ->
    yamka_auth:assert_permission(create_polls, {Ref, Seq}),

    {_, false} = {{Ref, status_packet:make(poll_error, "Zero or too many options", Seq)},
        (length(Options) > 10) or (length(Options) == 0)},
    Id = poll_e:create(Options),
    ets:insert(poll_awareness, {Id, {get(id), self()}}),
    entities_packet:make([#entity{type=poll, fields=#{
        id => Id, options => Options, total_votes => 0,
        option_votes => [0 || _ <- Options]}}], Seq);


%% votes in a poll
handle_entity(#entity{type=poll, fields=#{id:=Id, self_vote:=Option}}, Seq, Ref) ->
    yamka_auth:assert_permission(vote_in_polls, {Ref, Seq}),

    {_, {error, novote}} = {{Ref, status_packet:make(poll_error, "Already voted", Seq)},
        poll_e:get_vote(Id, get(id))},
    {_, ok} = {status_packet:make(poll_error, "Invalid option", Seq), poll_e:vote(Id, get(id), Option)},
    normal_client:icpc_broadcast_to_aware(poll_awareness,
        #entity{type=poll, fields=poll_e:get(Id)}, [id, total_votes, option_votes]),
    none.





%% gets a user
handle_get_request(#entity_get_rq{type=user, id=Id, pagination=none, context=none}, _Ref) ->
    ets:insert(user_awareness, {Id, {get(id), self()}}),

    true = yamka_auth:has_permission(see_profile),
    Self = user_e:get(get(id)),
    IsSelf = Id == get(id),
    Online = user_e:online(Id),
    Unfiltered = user_e:get(Id),

    Dm = case channel_e:get_dm([get(id), Id]) of
        nodm -> #{};
        DmId -> #{dm_channel => DmId}
    end,

    Mfa = maps:merge(Dm, #{mfa_enabled => maps:get(mfa_secret, Unfiltered) =/= null}),
    Agents = maps:merge(Mfa, if IsSelf -> #{agents => agent_e:get_by_user(Id)}; true -> #{} end),
    
    FilteredFields = maps:filter(fun(K, _) ->
        case K of
            id              -> true;
            email           -> IsSelf;
            email_confirmed -> IsSelf;
            mfa_enabled     -> IsSelf;
            name            -> true;
            tag             -> true;
            status          -> true;
            status_text     -> true;
            ava_file        -> true;
            friends         -> yamka_auth:has_permission(see_relationships);
            blocked         -> yamka_auth:has_permission(see_relationships) and IsSelf;
            pending_in      -> yamka_auth:has_permission(see_relationships) and IsSelf;
            pending_out     -> yamka_auth:has_permission(see_relationships) and IsSelf;
            dm_channel      -> yamka_auth:has_permission(see_direct_messages);
            groups          -> yamka_auth:has_permission(see_groups);
            badges          -> true;
            bot_owner       -> true;
            _ -> false
        end
    end, maps:map(fun(K, V) ->
            case K of
                status -> if
                        (V /= offline) and not Online -> offline;
                        true -> V
                    end;
                groups  -> utils:intersect_lists([V, maps:get(groups,  Self)]);
                friends -> utils:intersect_lists([V, maps:get(friends, Self)]);
                _ -> V
            end
        end, Unfiltered)),
    #entity{type=user, fields=maps:merge(FilteredFields, Agents)};


%% gets a user in context of a group
handle_get_request(#entity_get_rq{type=user, id=Id, pagination=none, context=
        #entity_context{type=group, id=_Group}}, _Ref) ->
    % TODO
    #entity{type=user, fields=#{id => Id, color => 0}};


%% gets a file
handle_get_request(#entity_get_rq{type=file, id=Id, pagination=none, context=none}, _Ref) ->
    % there are no permission restrictions on file accesses
    #entity{type=file, fields=file_e:get(Id)};


%% gets a channel
handle_get_request(#entity_get_rq{type=channel, id=Id, pagination=none, context=none}, _Ref) ->
    ets:insert(chan_awareness, {Id, {get(id), self()}}),

    Unfiltered = channel_e:get(Id),
    {UnreadLcid, UnreadId} = channel_e:get_unread(Id, get(id)),
    Mentions = channel_e:get_mentions(Id, get(id)),
    Filtered = maps:filter(fun(K, _) ->
            case K of
                lcid  -> false;
                perms -> false;
                _     -> true
            end
        end, Unfiltered),
    UnreadCnt = maps:get(lcid, Unfiltered) - UnreadLcid,
    AddMap = case UnreadCnt of
            0 -> #{unread => 0};
            _ -> #{unread => UnreadCnt, first_unread => UnreadId}
        end,
    #entity{type=channel, fields=maps:merge(
        maps:merge(Filtered, AddMap),
        #{typing   => channel_e:get_typing(Id),
          mentions => Mentions})};


%% gets channel messages
handle_get_request(#entity_get_rq{type=channel, id=Id, pagination=#entity_pagination{
        field=4, dir=Dir, from=From, cnt=Cnt}, context=none}, Ref) ->
    #{group := Group} = channel_e:get(Id),
    yamka_auth:assert_permission(if
        Group =/= 0 ->
            group_e:assert_permission(Group, read_messages, Ref),
            read_group_message_history;
        true -> read_direct_message_history
    end, Ref),
    #entity{type=channel, fields=#{id => Id, messages => channel_e:get_messages(Id, From, Cnt, Dir)}};


%% gets a message by id
handle_get_request(#entity_get_rq{type=message, id=Id}, _Ref) ->
    Filtered = maps:filter(fun(K, _) -> K /= lcid end, message_e:get(Id)),
    StateMap = #{states => message_e:get_states(Id), latest => #entity{type=message_state, fields=
        message_state_e:get(message_e:get_latest_state(Id))}},
    #entity{type=message, fields=maps:merge(Filtered, StateMap)};


%% gets a message state by id
handle_get_request(#entity_get_rq{type=message_state, id=Id, pagination=none, context=none}, _Ref) ->
    #entity{type=message_state, fields=message_state_e:get(Id)};


%% gets a group by id
handle_get_request(#entity_get_rq{type=group, id=Id, pagination=none, context=none}, _Ref) ->
    ets:insert(group_awareness, {Id, {get(id), self()}}),
    #entity{type=group, fields=group_e:get(Id)};


%% gets a role by id
handle_get_request(#entity_get_rq{type=role, id=Id, pagination=none, context=none}, _Ref) ->
    #entity{type=role, fields=role_e:get(Id)};


%% gets role members
handle_get_request(#entity_get_rq{type=role, id=Id, pagination=#entity_pagination{
        field=6, dir=Dir, from=From, cnt=Cnt}, context=none}, Ref) ->
    #{group := Group} = role_e:get(Id),
    group_e:assert_permission(Group, see_members, Ref),
    #entity{type=role, fields=#{id => Id, members => role_e:get_members(Id, From, Cnt, Dir)}};


%% gets a poll by id
handle_get_request(#entity_get_rq{type=poll, id=Id, pagination=none, context=none}, _Ref) ->
    ets:insert(poll_awareness, {Id, {get(id), self()}}),
    Main = poll_e:get(Id),
    Fields = case poll_e:get_vote(Id, get(id)) of
        {error, novote} -> Main;
        {ok, Option}    -> maps:merge(Main, #{self_vote => Option})
    end,
    #entity{type=poll, fields=Fields};


%% gets an agent by id
handle_get_request(#entity_get_rq{type=agent, id=Id, pagination=none, context=none}, _Ref) ->
    #entity{type=agent, fields=agent_e:get(Id)}.





%% encodes entities
encode_field(_Proto, number,   V, {Size})       -> datatypes:enc_num(V, Size);
encode_field(_Proto, string,   V, {})           -> datatypes:enc_str(V);
encode_field(_Proto, atom,     V, {Size, Map})  -> datatypes:enc_num(maps:get(V, utils:swap_map(Map)), Size);
encode_field(_Proto, bool,     V, {})           -> datatypes:enc_bool(V);
encode_field(_Proto, num_list, V, {Size})       -> datatypes:enc_num_list(V, Size);
encode_field(_Proto, str_list, V, {})           -> datatypes:enc_list(V, fun datatypes:enc_str/1, 2);
encode_field(_Proto, list,     V, {LS, EF, _})  -> datatypes:enc_list(V, EF, LS);
encode_field( Proto, entity,   V, {})           -> entity:encode(V, Proto);
encode_field(_Proto, bin,      V, {specified})  -> <<(byte_size(V)):16/unsigned, V/bitstring>>;
encode_field(_Proto, bin,      V, {Size})       -> Size = byte_size(V), V.
encode_field({{Id, Type, Args}, Value}, Proto) ->
    Repr = encode_field(Proto, Type, Value, Args),
    IdBin = datatypes:enc_num(Id, 1),
    <<IdBin/binary, Repr/binary>>.

encode(#entity{type=Type, fields=Fields}, Proto) ->
    TypeBin        = datatypes:enc_num(maps:get(Type, ?REVERSE_ENTITY_MAP), 1),
    Structure      = structure(Proto, Type),

    FieldsToEncode = utils:intersect_lists([maps:keys(Fields), maps:keys(Structure)]),
    FieldValues    = [{maps:get(K, Structure), maps:get(K, Fields)} || K <- FieldsToEncode],

    BinaryRepr = datatypes:enc_list(FieldValues,
        fun(F) -> encode_field(F, Proto) end, 1),
    <<TypeBin/binary, BinaryRepr/binary>>.

%% filters entity fields
filter(#entity{fields=Fields}=E, Allowed) ->
    E#entity{fields=maps:from_list(
        lists:filter(fun({K, _}) -> lists:member(K, [id|Allowed]) end,
            maps:to_list(Fields))
    )}.

%% finds a field descriptor by its ID in a reversed entity structure map
find_desc(RevS, Id) ->
    Desc = lists:nth(1, [D || {I, _, _} = D <- utils:map_keys(RevS), I == Id]),
    Name = maps:get(Desc, RevS),
    {Name, Desc}.

%% decodes entities
len_decode_field(_Proto, number,   V, {Size})       -> {datatypes:dec_num(V, Size), Size};
len_decode_field(_Proto, string,   V, {})           -> {datatypes:dec_str(V), datatypes:len_str(V)};
len_decode_field(_Proto, atom,     V, {Size, Map})  -> {maps:get(datatypes:dec_num(V, Size), Map), Size};
len_decode_field(_Proto, bool,     V, {})           -> {datatypes:dec_bool(V), 1};
len_decode_field(_Proto, num_list, V, {Size})       -> R=datatypes:dec_num_list(V, Size), {R, 2+(length(R)*Size)};
len_decode_field(_Proto, str_list, V, {})           -> datatypes:len_dec_list(V, fun datatypes:len_dec_str/1, 2);
len_decode_field(_Proto, list,     V, {LS, _, LDF}) -> datatypes:len_dec_list(V, LDF, LS);
len_decode_field( Proto, entity,   V, {})           -> entity:len_decode(V, Proto);
len_decode_field(_Proto, bin,      V, {specified})  -> <<Len:16/unsigned, Data/bitstring>> = V, {binary:part(Data, {0, Len}), Len + 2};
len_decode_field(_Proto, bin,      V, {Size})       -> {binary_part(V, {0, Size}), Size}.
len_decode_field(RevStructure, Bin, Proto) ->
    <<Id:8/unsigned, Repr/binary>> = Bin,
    % find the descriptor
    {Name, {Id, Type, Args}} = find_desc(RevStructure, Id),
    {FieldVal, Len} = len_decode_field(Proto, Type, Repr, Args),
    {{Name, FieldVal}, Len + 1}. % +1 because we have a one byte field ID

len_decode(Bin, Proto) ->
    <<TypeNum:8/unsigned, FieldsBin/binary>> = Bin,
    Type = maps:get(TypeNum, ?ENTITY_TYPE_MAP),
    RevStructure = utils:swap_map(structure(Proto, Type)),
    {FieldProplist, Len} = datatypes:len_dec_list(FieldsBin,
        fun(B) -> len_decode_field(RevStructure, B, Proto) end, 1),
    Fields = maps:from_list(FieldProplist),

    {#entity{type=Type, fields=Fields}, Len}.

%% constructs a "key1=?,key2=? ..." string and a list of cqerl bindings from #{key1=>val1, key2=>val2, ...}
construct_kv_str(Map) when is_map(Map) -> construct_kv_str(maps:to_list(Map));
construct_kv_str([]) -> {"", []};
construct_kv_str([{K,V}|T]) ->
    {RestStr, RestBind} = construct_kv_str(T),
    {atom_to_list(K) ++ "=?" ++ case RestStr of""->"";_->","end ++ RestStr, [{K,V}|RestBind]}.