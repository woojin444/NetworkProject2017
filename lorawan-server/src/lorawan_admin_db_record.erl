%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_admin_db_record).

-export([init/2]).
-export([is_authorized/2]).
-export([allowed_methods/2]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([resource_exists/2, generate_etag/2]).
-export([delete_resource/2]).

-export([handle_get/2, handle_write/2]).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").
-include("lorawan.hrl").

-record(state, {table, record, fields, key, module}).

init(Req, [Table, Record, Fields]) ->
    init0(Req, Table, Record, Fields, lorawan_admin);
init(Req, [Table, Record, Fields, Module]) ->
    init0(Req, Table, Record, Fields, Module).

init0(Req, Table, Record, Fields, Module) ->
    Key = lorawan_admin:parse_field(hd(Fields), cowboy_req:binding(hd(Fields), Req)),
    {cowboy_rest, Req, #state{table=Table, record=Record, fields=Fields, key=Key, module=Module}}.

is_authorized(Req, State) ->
    lorawan_admin:handle_authorization(Req, State).

allowed_methods(Req, #state{key=undefined}=State) ->
    {[<<"OPTIONS">>, <<"GET">>, <<"POST">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"OPTIONS">>, <<"GET">>, <<"PUT">>, <<"DELETE">>], Req, State}.

content_types_provided(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, []}, handle_get}
    ], Req, State}.

handle_get(Req, #state{key=undefined}=State) ->
    Req2 = cowboy_req:set_resp_header(<<"cache-control">>, <<"no-cache">>, Req),
    paginate(Req2, State,
        sort(Req2, read_records(Req2, State)));
handle_get(Req, #state{table=Table, key=Key}=State) ->
    Req2 = cowboy_req:set_resp_header(<<"cache-control">>, <<"no-cache">>, Req),
    [Rec] = mnesia:dirty_read(Table, Key),
    {jsx:encode(build_record(Rec, State)), Req2, State}.

paginate(Req, State, List) ->
    case cowboy_req:match_qs([{'_page', [], <<"1">>}, {'_perPage', [], undefined}], Req) of
        #{'_perPage' := undefined} ->
            {jsx:encode(List), Req, State};
        #{'_page' := Page0, '_perPage' := PerPage0} ->
            {Page, PerPage} = {binary_to_integer(Page0), binary_to_integer(PerPage0)},
            Req2 = cowboy_req:set_resp_header(<<"x-total-count">>, integer_to_binary(length(List)), Req),
            {jsx:encode(lists:sublist(List, 1+(Page-1)*PerPage, PerPage)), Req2, State}
    end.

sort(Req, List) ->
    case cowboy_req:match_qs([{'_sortDir', [], <<"ASC">>}, {'_sortField', [], undefined}], Req) of
        #{'_sortField' := undefined} ->
            List;
        #{'_sortDir' := <<"ASC">>, '_sortField' := Field} ->
            lists:sort(
                fun(A0,B0) ->
                    case {get_field(Field, A0), get_field(Field, B0)} of
                        {null, _B} -> true;
                        {_A, null} -> false;
                        {A, B} -> A =< B
                    end
                end, List);
        #{'_sortDir' := <<"DESC">>, '_sortField' := Field} ->
            lists:sort(
                fun(A0,B0) ->
                    case {get_field(Field, A0), get_field(Field, B0)} of
                        {_A, null} -> true;
                        {null, _B} -> false;
                        {A, B} -> A >= B
                    end
                end, List)
    end.

get_field(Field, Value) ->
    get_fields(binary:split(Field, <<$.>>), Value).

get_fields(_Any, undefined) ->
    null;
get_fields([Field | Rest], Value) ->
    AField = binary_to_existing_atom(Field, latin1),
    get_fields(Rest, maps:get(AField, Value, null));
get_fields([], Value) ->
    Value.

read_records(Req, #state{table=Table, record=Record, fields=Fields, module=Module}=State) ->
    Filter = apply(Module, parse, [get_filters(Req)]),
    Match = list_to_tuple([Record|[maps:get(X, Filter, '_') || X <- Fields]]),
    lists:map(
        fun(Rec)-> build_record(Rec, State) end,
        mnesia:dirty_select(Table, [{Match, [], ['$_']}])).

get_filters(Req) ->
    case cowboy_req:match_qs([{'_filters', [], <<"{}">>}], Req) of
        #{'_filters' := Filter} ->
            jsx:decode(Filter, [return_maps, {labels, atom}])
    end.

build_record(Rec, #state{fields=Fields, module=Module}) ->
    Record =
        apply(Module, build, [
            maps:from_list(
                lists:filter(
                    % TODO: isn't this removed twice (see admin:build)
                    fun ({_, undefined}) -> false;
                        (_) -> true
                    end,
                    lists:zip(Fields, tl(tuple_to_list(Rec)))))
            ]),
    case apply(Module, check_health, [Rec]) of
        {Decay, Alerts} ->
            Record#{health_decay => Decay, health_alerts => Alerts};
        undefined ->
            Record
    end.

content_types_accepted(Req, State) ->
    {[
        {{<<"application">>, <<"json">>, '*'}, handle_write}
    ], Req, State}.

handle_write(Req, State) ->
    {ok, Data, Req2} = cowboy_req:read_body(Req),
    case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
        Struct when is_list(Struct); is_map(Struct) ->
            ok = import_records(Struct, State),
            {true, Req2, State};
        _Else ->
            lager:debug("Bad JSON in HTTP request"),
            {stop, cowboy_req:reply(400, Req2), State}
    end.

import_records([], _State) -> ok;
import_records([First|Rest], State) ->
    {atomic, ok} = write_record(First, State),
    import_records(Rest, State);
import_records(Object, State) when is_map(Object) ->
    {atomic, ok} = write_record(Object, State),
    ok.

write_record(List, #state{table=Table, record=Record, fields=Fields, module=Module}) ->
    List2 = apply(Module, parse, [List]),
    Rec = list_to_tuple([Record | [maps:get(X, List2, undefined) || X <- Fields]]),
    % make sure there is a primary key
    case element(2, Rec) of
        undefined ->
            {error, null_key};
        _Else ->
            mnesia:transaction(fun() ->
                mnesia:write(Table, Rec, write) end)
    end.

resource_exists(Req, #state{key=undefined}=State) ->
    {true, Req, State};
resource_exists(Req, #state{table=Table, key=Key}=State) ->
    case mnesia:dirty_read(Table, Key) of
        [] -> {false, Req, State};
        [_] -> {true, Req, State}
    end.

generate_etag(Req, #state{key=undefined}=State) ->
    {undefined, Req, State};
generate_etag(Req, #state{table=Table, key=Key, module=Module}=State) ->
    case mnesia:dirty_read(Table, Key) of
        [] ->
            {undefined, Req, State};
        [Rec] ->
            Health = apply(Module, check_health, [Rec]),
            Hash = base64:encode(crypto:hash(sha256, term_to_binary({Rec, Health}))),
            {<<$", Hash/binary, $">>, Req, State}
    end.

delete_resource(Req, #state{table=Table, key=Key}=State) ->
    ok = mnesia:dirty_delete(Table, Key),
    {true, Req, State}.

% end of file
