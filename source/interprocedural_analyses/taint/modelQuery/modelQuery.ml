(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Ast
open Analysis
open Interprocedural
open Taint
open Model
open Pyre

module DumpModelQueryResults : sig
  val dump : path:Path.t -> models:Taint.Result.call_model Callable.Map.t -> unit
end = struct
  let dump ~path ~models =
    Log.warning "Emitting the model query results to `%s`" (Path.absolute path);
    let content =
      let to_json (callable, model) =
        `Assoc
          [
            "callable", `String (Callable.external_target_name callable);
            ( "model",
              `List (Taint.Result.externalize ~filename_lookup:(fun _ -> None) callable None model)
            );
          ]
      in
      models
      |> Map.to_alist
      |> fun models -> `List (List.map models ~f:to_json) |> Yojson.Safe.pretty_to_string
    in
    path |> File.create ~content |> File.write
end

let matches_pattern ~pattern = Re2.matches (Re2.create_exn pattern)

let rec callable_matches_constraint query_constraint ~resolution ~callable =
  let get_callable_type =
    Memo.unit (fun () ->
        let callable_type = Callable.get_module_and_definition ~resolution callable >>| snd in
        if Option.is_none callable_type then
          Log.error "Could not find callable type for callable: `%s`" (Callable.show callable);
        callable_type)
  in
  let matches_annotation_constraint ~annotation_constraint ~annotation =
    match annotation_constraint with
    | ModelQuery.IsAnnotatedTypeConstraint -> (
        match annotation with
        | Type.Annotated _ -> true
        | _ -> false )
  in
  match query_constraint with
  | ModelQuery.DecoratorNameConstraint name -> (
      let callable_type = get_callable_type () in
      match callable_type with
      | Some
          {
            Node.value =
              { Statement.Define.signature = { Statement.Define.Signature.decorators; _ }; _ };
            _;
          }
        when not (List.is_empty decorators) ->
          let matches_pattern = matches_pattern ~pattern:name in
          let decorator_name_matches
              { Statement.Decorator.name = { Node.value = decorator_name; _ }; _ }
            =
            matches_pattern (Reference.show decorator_name)
          in
          List.exists decorators ~f:decorator_name_matches
      | _ -> false )
  | ModelQuery.NameConstraint pattern ->
      matches_pattern ~pattern (Callable.external_target_name callable)
  | ModelQuery.ReturnConstraint annotation_constraint -> (
      let callable_type = get_callable_type () in
      match callable_type with
      | Some
          {
            Node.value =
              {
                Statement.Define.signature =
                  { Statement.Define.Signature.return_annotation = Some annotation; _ };
                _;
              };
            _;
          } ->
          matches_annotation_constraint
            ~annotation_constraint
            ~annotation:(GlobalResolution.parse_annotation resolution annotation)
      | _ -> false )
  | ModelQuery.AnyParameterConstraint (ModelQuery.AnnotationConstraint annotation_constraint) -> (
      let callable_type = get_callable_type () in
      match callable_type with
      | Some
          {
            Node.value =
              { Statement.Define.signature = { Statement.Define.Signature.parameters; _ }; _ };
            _;
          } ->
          List.exists
            parameters
            ~f:(fun { Node.value = { Expression.Parameter.annotation; _ }; _ } ->
              match annotation with
              | Some annotation ->
                  matches_annotation_constraint
                    ~annotation_constraint
                    ~annotation:(GlobalResolution.parse_annotation resolution annotation)
              | None -> false)
      | _ -> false )
  | ModelQuery.AnyOf constraints ->
      List.exists constraints ~f:(callable_matches_constraint ~resolution ~callable)
  | ModelQuery.ParentConstraint (Equals class_name) ->
      Callable.class_name callable >>| String.equal class_name |> Option.value ~default:false
  | ModelQuery.ParentConstraint (Extends class_name) ->
      Callable.class_name callable
      >>| GlobalResolution.immediate_parents ~resolution
      >>| (fun parents -> List.mem parents class_name ~equal:String.equal)
      |> Option.value ~default:false
  | ModelQuery.ParentConstraint (Matches class_pattern) ->
      Callable.class_name callable >>| Re2.matches class_pattern |> Option.value ~default:false


let apply_callable_productions ~resolution ~productions ~callable =
  let definition = Callable.get_module_and_definition ~resolution callable in
  match definition with
  | None -> []
  | Some
      ( _,
        {
          Node.value =
            {
              Statement.Define.signature =
                { Statement.Define.Signature.parameters; return_annotation; _ };
              _;
            };
          _;
        } ) ->
      let production_to_taint ~annotation ~production =
        let open Expression in
        let get_subkind_from_annotation ~pattern annotation =
          let get_annotation_of_type annotation =
            match annotation >>| Node.value with
            | Some (Expression.Call { Call.callee = { Node.value = callee; _ }; arguments }) -> (
                match callee with
                | Name
                    (Name.Attribute
                      {
                        base =
                          { Node.value = Name (Name.Attribute { attribute = "Annotated"; _ }); _ };
                        _;
                      }) -> (
                    match arguments with
                    | [
                     {
                       Call.Argument.value = { Node.value = Expression.Tuple [_; annotation]; _ };
                       _;
                     };
                    ] ->
                        Some annotation
                    | _ -> None )
                | _ -> None )
            | _ -> None
          in
          match get_annotation_of_type annotation with
          | Some
              {
                Node.value =
                  Expression.Call
                    {
                      Call.callee = { Node.value = Name (Name.Identifier callee_name); _ };
                      arguments =
                        [
                          {
                            Call.Argument.value = { Node.value = Name (Name.Identifier subkind); _ };
                            _;
                          };
                        ];
                    };
                _;
              } ->
              if String.equal callee_name pattern then
                Some subkind
              else
                None
          | _ -> None
        in
        match production with
        | ModelQuery.TaintAnnotation taint_annotation -> Some taint_annotation
        | ModelQuery.ParametricSourceFromAnnotation { source_pattern; kind } ->
            get_subkind_from_annotation ~pattern:source_pattern annotation
            >>| fun subkind ->
            Source
              {
                source = Sources.ParametricSource { source_name = kind; subkind };
                breadcrumbs = [];
                path = [];
                leaf_names = [];
                leaf_name_provided = false;
              }
        | ModelQuery.ParametricSinkFromAnnotation { sink_pattern; kind } ->
            get_subkind_from_annotation ~pattern:sink_pattern annotation
            >>| fun subkind ->
            Sink
              {
                sink = Sinks.ParametricSink { sink_name = kind; subkind };
                breadcrumbs = [];
                path = [];
                leaf_names = [];
                leaf_name_provided = false;
              }
      in
      let normalized_parameters = AccessPath.Root.normalize_parameters parameters in
      let apply_production = function
        | ModelQuery.ReturnTaint productions ->
            List.filter_map productions ~f:(fun production ->
                production_to_taint ~annotation:return_annotation ~production
                >>| fun taint -> ReturnAnnotation, taint)
        | ModelQuery.ParameterTaint { name; taint = productions } -> (
            let parameter =
              List.find_map
                normalized_parameters
                ~f:(fun ( root,
                          parameter_name,
                          { Node.value = { Expression.Parameter.annotation; _ }; _ } )
                        ->
                  if Identifier.equal_sanitized parameter_name name then
                    Some (root, annotation)
                  else
                    None)
            in
            match parameter with
            | Some (parameter, annotation) ->
                List.filter_map productions ~f:(fun production ->
                    production_to_taint ~annotation ~production
                    >>| fun taint -> ParameterAnnotation parameter, taint)
            | None -> [] )
        | ModelQuery.PositionalParameterTaint { index; taint = productions } -> (
            let parameter =
              List.find_map
                normalized_parameters
                ~f:(fun (root, _, { Node.value = { Expression.Parameter.annotation; _ }; _ }) ->
                  match root with
                  | AccessPath.Root.PositionalParameter { position; _ } when position = index ->
                      Some (root, annotation)
                  | _ -> None)
            in
            match parameter with
            | Some (parameter, annotation) ->
                List.filter_map productions ~f:(fun production ->
                    production_to_taint ~annotation ~production
                    >>| fun taint -> ParameterAnnotation parameter, taint)
            | None -> [] )
        | ModelQuery.AllParametersTaint { excludes; taint } ->
            let apply_parameter_production
                ( (root, parameter_name, { Node.value = { Expression.Parameter.annotation; _ }; _ }),
                  production )
              =
              if
                (not (List.is_empty excludes))
                && List.mem excludes ~equal:String.equal (Identifier.sanitized parameter_name)
              then
                None
              else
                production_to_taint ~annotation ~production
                >>| fun taint -> ParameterAnnotation root, taint
            in
            List.cartesian_product normalized_parameters taint
            |> List.filter_map ~f:apply_parameter_production
        | ModelQuery.AttributeTaint _ -> failwith "impossible case"
      in
      List.concat_map productions ~f:apply_production


let apply_callable_query_rule
    ~verbose
    ~resolution
    ~rule:{ ModelQuery.rule_kind; query; productions; name }
    ~callable
  =
  let kind_matches =
    match callable, rule_kind with
    | `Function _, ModelQuery.FunctionModel
    | `Method _, ModelQuery.MethodModel ->
        true
    | _ -> false
  in

  if kind_matches && List.for_all ~f:(callable_matches_constraint ~resolution ~callable) query then begin
    if verbose then
      Log.info
        "Callable `%a` matches all constraints for the model query rule%s."
        Callable.pretty_print
        (callable :> Callable.t)
        (name |> Option.map ~f:(Format.sprintf " `%s`") |> Option.value ~default:"");
    apply_callable_productions ~resolution ~productions ~callable
  end
  else
    []


let rec attribute_matches_constraint query_constraint ~resolution ~attribute =
  let class_name = Reference.prefix attribute >>| Reference.show in
  match query_constraint with
  | ModelQuery.NameConstraint pattern -> matches_pattern ~pattern (Reference.show attribute)
  | ModelQuery.AnyOf constraints ->
      List.exists constraints ~f:(attribute_matches_constraint ~resolution ~attribute)
  | ModelQuery.ParentConstraint (Equals query_class_name) ->
      class_name >>| String.equal query_class_name |> Option.value ~default:false
  | ModelQuery.ParentConstraint (Extends query_class_name) ->
      class_name
      >>| GlobalResolution.immediate_parents ~resolution
      >>| (fun parents -> List.mem parents query_class_name ~equal:String.equal)
      |> Option.value ~default:false
  | ModelQuery.ParentConstraint (Matches class_pattern) ->
      class_name >>| Re2.matches class_pattern |> Option.value ~default:false
  | _ -> failwith "impossible case"


let apply_attribute_productions ~productions =
  let production_to_taint = function
    | ModelQuery.TaintAnnotation taint_annotation -> Some taint_annotation
    | _ -> None
  in
  let apply_production = function
    | ModelQuery.AttributeTaint productions -> List.filter_map productions ~f:production_to_taint
    | _ -> failwith "impossible case"
  in
  List.concat_map productions ~f:apply_production


let apply_attribute_query_rule
    ~verbose
    ~resolution
    ~rule:{ ModelQuery.rule_kind; query; productions; name }
    ~attribute
  =
  let kind_matches =
    match rule_kind with
    | ModelQuery.AttributeModel -> true
    | _ -> false
  in

  if kind_matches && List.for_all ~f:(attribute_matches_constraint ~resolution ~attribute) query
  then begin
    if verbose then
      Log.info
        "Attribute `%s` matches all constraints for the model query rule%s."
        (Reference.show attribute)
        (name |> Option.map ~f:(Format.sprintf " `%s`") |> Option.value ~default:"");
    apply_attribute_productions ~productions
  end
  else
    []


let get_class_attributes ~global_resolution ~class_name =
  let class_summary =
    GlobalResolution.class_definition global_resolution (Type.Primitive class_name) >>| Node.value
  in
  match class_summary with
  | None -> []
  | Some { ClassSummary.attribute_components; name = class_name_reference; _ } ->
      let attributes, constructor_attributes =
        ( Statement.Class.attributes ~include_generated_attributes:false attribute_components,
          Statement.Class.constructor_attributes attribute_components )
      in
      let all_attributes =
        Identifier.SerializableMap.union (fun _ x _ -> Some x) attributes constructor_attributes
      in
      Identifier.SerializableMap.fold
        (fun attribute _ accumulator ->
          Reference.create ~prefix:class_name_reference attribute :: accumulator)
        all_attributes
        []


let apply_all_rules
    ~resolution
    ~scheduler
    ~configuration
    ~rule_filter
    ~rules
    ~callables
    ~environment
    ~models
  =
  let global_resolution = Resolution.global_resolution resolution in
  if List.length rules > 0 then (
    let sources_to_keep, sinks_to_keep =
      ModelParser.compute_sources_and_sinks_to_keep ~configuration ~rule_filter
    in
    let merge_models new_models models =
      Map.merge_skewed new_models models ~combine:(fun ~key:_ left right ->
          Taint.Result.join ~iteration:0 left right)
    in
    let attribute_rules, callable_rules =
      List.partition_tf
        ~f:(fun { ModelQuery.rule_kind; _ } ->
          match rule_kind with
          | ModelQuery.AttributeModel -> true
          | _ -> false)
        rules
    in

    (* Generate models for functions and methods. *)
    let apply_rules_for_callable models callable =
      let taint_to_model =
        List.concat_map callable_rules ~f:(fun rule ->
            apply_callable_query_rule
              ~verbose:(Option.is_some configuration.dump_model_query_results_path)
              ~resolution:global_resolution
              ~rule
              ~callable)
      in
      if not (List.is_empty taint_to_model) then (
        match
          ModelParser.create_callable_model_from_annotations
            ~resolution
            ~callable
            ~sources_to_keep
            ~sinks_to_keep
            taint_to_model
        with
        | Ok model ->
            let models =
              let model =
                match Callable.Map.find models (callable :> Callable.t) with
                | Some existing_model -> Taint.Result.join ~iteration:0 existing_model model
                | None -> model
              in
              Callable.Map.set models ~key:(callable :> Callable.t) ~data:model
            in
            models
        | Error error ->
            Log.error
              "Error while executing model query: %s"
              (Model.display_verification_error error);
            models )
      else
        models
    in
    let callables =
      List.filter_map callables ~f:(function
          | `Function _ as callable -> Some (callable :> Callable.real_target)
          | `Method _ as callable -> Some (callable :> Callable.real_target)
          | _ -> None)
    in
    let callable_models =
      Scheduler.map_reduce
        scheduler
        ~policy:
          (Scheduler.Policy.fixed_chunk_count
             ~minimum_chunk_size:500
             ~preferred_chunks_per_worker:1
             ())
        ~initial:Callable.Map.empty
        ~map:(fun models callables -> List.fold callables ~init:models ~f:apply_rules_for_callable)
        ~reduce:(fun new_models models ->
          Map.merge_skewed new_models models ~combine:(fun ~key:_ left right ->
              Taint.Result.join ~iteration:0 left right))
        ~inputs:callables
        ()
    in

    (* Generate models for attributes. *)
    let apply_rules_for_attribute models attribute =
      let taint_to_model =
        List.concat_map attribute_rules ~f:(fun rule ->
            apply_attribute_query_rule
              ~verbose:(Option.is_some configuration.dump_model_query_results_path)
              ~resolution:global_resolution
              ~rule
              ~attribute)
      in
      if not (List.is_empty taint_to_model) then (
        let callable = Callable.create_object attribute in
        match
          ModelParser.create_attribute_model_from_annotations
            ~resolution
            ~name:attribute
            ~sources_to_keep
            ~sinks_to_keep
            taint_to_model
        with
        | Ok model ->
            let models =
              let model =
                match Callable.Map.find models (callable :> Callable.t) with
                | Some existing_model -> Taint.Result.join ~iteration:0 existing_model model
                | None -> model
              in
              Callable.Map.set models ~key:(callable :> Callable.t) ~data:model
            in
            models
        | Error error ->
            Log.error
              "Error while executing model query: %s"
              (Model.display_verification_error error);
            models )
      else
        models
    in
    let attribute_models =
      if not (List.is_empty attribute_rules) then
        let all_classes =
          TypeEnvironment.ReadOnly.global_resolution environment
          |> GlobalResolution.unannotated_global_environment
          |> UnannotatedGlobalEnvironment.ReadOnly.all_classes
        in
        let attributes =
          List.concat_map all_classes ~f:(fun class_name ->
              get_class_attributes ~global_resolution ~class_name)
        in
        Scheduler.map_reduce
          scheduler
          ~policy:
            (Scheduler.Policy.fixed_chunk_count
               ~minimum_chunk_size:500
               ~preferred_chunks_per_worker:1
               ())
          ~initial:Callable.Map.empty
          ~map:(fun models attributes ->
            List.fold attributes ~init:models ~f:apply_rules_for_attribute)
          ~reduce:(fun new_models models ->
            Map.merge_skewed new_models models ~combine:(fun ~key:_ left right ->
                Taint.Result.join ~iteration:0 left right))
          ~inputs:attributes
          ()
      else
        Callable.Map.empty
    in
    let new_models = merge_models callable_models attribute_models in
    begin
      match configuration.dump_model_query_results_path with
      | Some path -> DumpModelQueryResults.dump ~path ~models:new_models
      | None -> ()
    end;
    merge_models new_models models )
  else
    models
