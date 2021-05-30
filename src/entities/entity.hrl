%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

-record(entity, {type=unknown, fields=#{}}).
-record(entity_pagination, {field=0, dir=unknown, from=0, cnt=0}).
-record(entity_context, {type=unknown, id=0}).
-record(entity_get_rq, {type=unknown, id=0, pagination=none, context=none}).
-record(message_section, {type=unknown, blob=0, text=""}).

-define(REVERSE_MESSAGE_SECTION_TYPE_MAP, utils:swap_map(?MESSAGE_SECTION_TYPE_MAP)).
-define(MESSAGE_SECTION_TYPE_MAP, #{
    0 => text,
    1 => file,
    2 => code,
    3 => quote,
    4 => invite,
    5 => user,
    6 => bot_ui,
    7 => poll
}).

-define(REVERSE_ENTITY_MAP, utils:swap_map(?ENTITY_TYPE_MAP)).
-define(ENTITY_TYPE_MAP, #{
    1 => user,
    2 => channel,
    3 => group,
    4 => message,
    5 => role,
    6 => file,
    7 => message_state,
    8 => poll,
    9 => agent
}).

-define(USER_STATUS_MAP, #{0 => offline, 1 => online, 2 => idle, 3 => dnd}).

-define(PERM_LEN, 64).
-define(PERMISSION_FLAGS, #{
    <<0:2>> => unset,
    <<1:2>> => no,
    <<2:2>> => yes
}).
-define(ROLE_PERMISSION_BITS, #{
    0  => read_messages,
    1  => send_messages,
    2  => see_members,
    3  => edit_group,
    4  => edit_channels,
    5  => edit_invites,
    6  => edit_roles,
    7  => kick_members,
    8  => ban_members,
    9  => view_log,
    10 => mention_higher_roles,
    11 => mention_higher_users,
    12 => delete_others_messages,
    13 => connect_to_voice,
    14 => speak_in_voice,
    15 => mute_others,
    16 => deafen_others
}).

-define(ENTITY_STRUCTURE, #{
    9 => #{
        user => #{
                id              => {0,  number,   {8}},
                email           => {1,  string,   {}},
                name            => {2,  string,   {}},
                tag             => {3,  number,   {3}},
                status          => {4,  atom,     {1, ?USER_STATUS_MAP}},
                status_text     => {5,  string,   {}},
                permissions     => {6,  bin,      {8}},
                ava_file        => {7,  number,   {8}},
                mfa_enabled     => {8,  bool,     {}},
                friends         => {9,  num_list, {8}},
                blocked         => {10, num_list, {8}},
                pending_in      => {11, num_list, {8}},
                pending_out     => {12, num_list, {8}},
                dm_channel      => {13, number,   {8}},
                groups          => {14, num_list, {8}},
                roles           => {15, num_list, {8}},
                color           => {16, number,   {4}},
                badges          => {17, num_list, {1}},
                bot_owner       => {18, number,   {8}},
                owned_bots      => {19, num_list, {8}},
                agents          => {20, num_list, {8}},
                email_confirmed => {21, bool,     {}}
            },
        channel => #{
                id            => {0,  number,   {8}},
                name          => {1,  string,   {}},
                members       => {2,  num_list, {8}},
                group         => {3,  number,   {8}},
                messages      => {4,  num_list, {8}},
                typing        => {5,  num_list, {8}},
                unread        => {7,  number,   {4}},
                first_unread  => {8,  number,   {8}},
                voice         => {9,  bool,     {}},
                voice_users   => {10, num_list, {8}},
                voice_status  => {11, list,     {2, fun datatypes:enc_chan_voice_status/1,
                                                    fun datatypes:len_dec_chan_voice_status/1}},
                mentions      => {12, num_list, {8}}
            },
        group => #{
                id            => {0, number,   {8}},
                name          => {1, string,   {}},
                channels      => {2, num_list, {8}},
                owner         => {3, number,   {8}},
                roles         => {4, num_list, {8}},
                icon          => {5, number,   {8}},
                invites       => {6, str_list, {}},
                everyone_role => {7, number,   {8}}
            },
        message => #{
                id      => {0, number,   {8}},
                states  => {1, num_list, {8}},
                channel => {2, number,   {8}},
                sender  => {3, number,   {8}},
                latest  => {4, entity,   {}}
            },
        role => #{
                id          => {0, number,   {8}},
                name        => {1, string,   {}},
                color       => {2, number,   {4}},
                group       => {3, number,   {8}},
                priority    => {4, number,   {2}},
                permissions => {5, bin,      {8}},
                members     => {6, num_list, {8}}
            },
        file => #{
                id         => {0, number, {8}},
                name       => {1, string, {}},
                pixel_size => {2, string, {}},
                preview    => {3, string, {}},
                length     => {4, number, {4}}
            },
        message_state => #{
                id        => {0, number, {8}},
                msg_id    => {1, number, {8}},
                sections  => {2, list,   {1, fun datatypes:enc_msg_section/1,
                                             fun datatypes:len_dec_msg_section/1}},
                encrypted => {3, bin,    {specified}}
            },
        poll => #{
                id           => {0, number,   {8}},
                options      => {1, str_list, {}},
                option_votes => {2, num_list, {3}},
                self_vote    => {3, number,   {1}},
                total_votes  => {4, number,   {3}}
            },
        agent => #{
                id     => {0, number, {8}},
                owner  => {1, number, {8}},
                type   => {2, number, {1}},
                name   => {3, string, {}},
                online => {4, bool,   {}}
            }
    }
}).