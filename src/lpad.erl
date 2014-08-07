%%% Copyright 2014 Garrett Smith <g@rre.tt>
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%% 
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%% 
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.

-module(lpad).

-export([run/1, run/2]).

-include_lib("kernel/include/file.hrl").

-define(INDEX_MODULE, index).

run(Args) ->
    run(cwd(), Args).

cwd() ->
    {ok, Dir} = file:get_cwd(),
    Dir.

run(Root, Args) ->
    handle_error(catch(run_impl(Root, Args))).

run_impl(Root, Args) ->
    lpad_session:init(Root),
    process_index(index_module(Root), Args).

handle_error({'EXIT', Err}) ->
    lpad_event:notify({exit, Err});
handle_error(ok) -> ok.

index_module(Root) ->
    compile_index(index_source(Root)).

index_source(Root) ->
    filename:join(Root, index_src_name()).

index_src_name() ->
    atom_to_list(?INDEX_MODULE) ++ ".erl".

compile_index(Src) ->
    CompileOpts =
        [export_all,
         return_errors, 
         binary,
         {i, lpad_include_dir()}],
    handle_index_compile(compile:file(Src, CompileOpts), Src).

lpad_include_dir() -> filename:join(app_dir(), "include").

app_dir() -> filename:dirname(ebin_dir()).

ebin_dir() -> filename:dirname(code:which(?MODULE)).

handle_index_compile({ok, Module, Bin}, Src) ->
    handle_index_load(code:load_binary(Module, Src, Bin));
handle_index_compile({error, Errors, Warnings}, Src) ->
    error({index_compile, Src, Errors, Warnings}).

handle_index_load({module, Module}) ->
    Module;
handle_index_load({error, Err}) ->
    error({index_load, Err}).

process_index(Index, Args) ->
    DataLoaders = init_data_loaders(Index),
    DataSpecs = data_specs(Index, Args),
    Data = data(DataSpecs, DataLoaders),
    Generators = init_generators(Index),
    GeneratorSpecs = generator_specs(Index, Data),
    Targets = generator_targets(GeneratorSpecs, Data, Generators),
    generate(Targets, data_sources(Data)).

init_generators(_Index) ->
    [lpad_template,
     lpad_file].

init_data_loaders(_Index) ->
    [lpad_eterm,
     lpad_json,
     lpad_markdown].

data_specs(Index, Args) ->
    lpad_util:maps_to_proplists(Index:data(Args)).

data([{_, _}|_]=DSpecs, DLs) ->
    add_index_source(acc_data(DSpecs, DLs, []));
data(DSpec, DLs) ->
    apply_data_loader(DLs, DSpec, '$root').

acc_data([DSpec|Rest], DLs, Data) ->
    acc_data(Rest, DLs, apply_data_loader(DLs, DSpec, Data));
acc_data([], _DLs, Data) ->
    Data.

apply_data_loader([DL|Rest], DSpec, Data) ->
    handle_data_loader_result(
      DL:handle_data_spec(DSpec, Data),
      Rest, DSpec);
apply_data_loader([], {Name, Value}, Data) ->
    [{Name, Value}|Data];
apply_data_loader([], DSpec, _Data) ->
    error({unhandled_data_spec, DSpec}).

handle_data_loader_result({continue, Data}, Rest, DSpec) ->
    apply_data_loader(Rest, DSpec, Data);
handle_data_loader_result({ok, Data}, _Rest, _DSpec) ->
    Data;
handle_data_loader_result({stop, Reason}, _Rest, DSpec) ->
    error({data_loader_stop, Reason, DSpec}).

add_index_source(Data) ->
    IndexSource = index_source(lpad_session:root()),
    [{'__file__', IndexSource}|Data].

generator_specs(Index, Data) ->
    lpad_util:maps_to_proplists(Index:site(Data)).

generator_targets(GSpecs, Data, Gs) ->
    acc_targets(GSpecs, Data, Gs, []).

acc_targets([GSpec|Rest], Data, Gs, Acc) ->
    {NewTargets, NewData} = apply_generator(Gs, GSpec, Data),
    acc_targets(Rest, NewData, Gs, acc_items(NewTargets, Acc));
acc_targets([], _Data, _Gs, Acc) ->
    lists:reverse(Acc).

apply_generator([G|Rest], GSpec, Data) ->
    handle_generator_result(
      G:handle_generator_spec(GSpec, Data),
      Rest, GSpec);
apply_generator([], GSpec, _Data) ->
    error({unhandled_generator_spec, GSpec}).

handle_generator_result({continue, Data}, Rest, GSpec) ->
    apply_generator(Rest, GSpec, Data);
handle_generator_result({ok, Targets, Data}, _Rest, _GSpec) ->
    {Targets, Data};
handle_generator_result({stop, Reason}, _Rest, GSpec) ->
    error({generator_stop, Reason, GSpec}).

acc_items([Item|Rest], Acc) ->
    acc_items(Rest, [Item|Acc]);
acc_items([], Acc) ->
    Acc.

data_sources([{_, _}|_]=Data) ->
    acc_data_sources(Data, []).

acc_data_sources([{'__file__', Src}|Rest], Acc) ->
    acc_data_sources(Rest, [Src|Acc]);
acc_data_sources([{_, Value}|Rest], Acc) ->
    acc_data_sources(Rest, acc_data_sources(Value, Acc));
acc_data_sources(_, Acc) -> Acc.

generate([{Target, TargetSources, Generator}|Rest], DataSources) ->
    AllSources = resolve_sources(TargetSources, DataSources),
    maybe_generate_target(target_stale(Target, AllSources), Generator),
    generate(Rest, DataSources);
generate([], _DataSources) ->
    ok.

resolve_sources(TargetSources, DataSources) ->
    acc_resolved_sources(TargetSources, DataSources, []).

acc_resolved_sources(['$data'|Rest], DataSources, Acc) ->
    acc_resolved_sources(Rest, [], acc_items(DataSources, Acc));
acc_resolved_sources([Source|Rest], DataSources, Acc) ->
    acc_resolved_sources(Rest, DataSources, [Source|Acc]);
acc_resolved_sources([], _DataSources, Acc) -> Acc.

target_stale(Target, Sources) ->
    any_source_newer(modified(Target), map_modified(Sources)).

-define(NO_MTIME, {{0,0,0},{0,0,0}}).

modified(File) ->
    case file:read_file_info(File) of
        {ok, #file_info{mtime=Modified}} -> Modified;
        _ -> ?NO_MTIME
    end.

map_modified(Files) ->
    [modified(File) || File <- Files].

any_source_newer(?NO_MTIME, _Sources) -> true;
any_source_newer(_Target, [force_modified|_]) -> true;
any_source_newer(Target, [Source|_]) when Source > Target -> true;
any_source_newer(Target, [_|Rest]) -> any_source_newer(Target, Rest);
any_source_newer(_Target, []) -> false.

maybe_generate_target(true, Generator) -> Generator();
maybe_generate_target(false, _Generator) -> ok.