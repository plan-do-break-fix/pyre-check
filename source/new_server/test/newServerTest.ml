(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Newserver
module Path = Pyre.Path

module Client = struct
  type t = {
    context: test_ctxt;
    server_state: ServerState.t ref;
    input_channel: Lwt_io.input_channel;
    output_channel: Lwt_io.output_channel;
  }

  let current_server_state { server_state; _ } = !server_state

  let send_raw_request { input_channel; output_channel; _ } raw_request =
    let open Lwt in
    Lwt_io.write_line output_channel raw_request >>= fun _ -> Lwt_io.read_line input_channel


  let parse_raw_response ~f raw_response =
    try
      match f (Yojson.Safe.from_string raw_response) with
      | Ok response -> Result.Ok response
      | Error _ -> Result.Error raw_response
    with
    | _ -> Result.Error raw_response


  let send_request client request =
    let open Lwt in
    Request.to_yojson request
    |> Yojson.Safe.to_string
    |> send_raw_request client
    >>= fun raw_response -> return (parse_raw_response ~f:Response.of_yojson raw_response)


  let assert_response_equal ~context expected actual =
    assert_equal
      ~ctxt:context
      ~cmp:[%compare.equal: Response.t]
      ~printer:(fun response -> Format.asprintf "%a" Sexp.pp_hum (Response.sexp_of_t response))
      expected
      actual


  let assert_subscription_response_equal ~context expected actual =
    assert_equal
      ~ctxt:context
      ~cmp:[%compare.equal: Subscription.Response.t]
      ~printer:(fun response ->
        Format.asprintf "%a" Sexp.pp_hum (Subscription.Response.sexp_of_t response))
      expected
      actual


  let assert_response ~request ~expected ({ context; _ } as client) =
    let open Lwt in
    send_request client request
    >>= function
    | Result.Error raw_response ->
        let message =
          Format.sprintf "Cannot decode the received JSON from server: %s" raw_response
        in
        assert_failure message
    | Result.Ok actual ->
        assert_response_equal ~context expected actual;
        return_unit


  let subscribe ~subscription ~expected_response ({ context; _ } as client) =
    let open Lwt in
    send_raw_request client (Subscription.Request.to_yojson subscription |> Yojson.Safe.to_string)
    >>= fun raw_response ->
    match parse_raw_response ~f:Response.of_yojson raw_response with
    | Result.Error raw_response ->
        let message =
          Format.sprintf
            "Cannot decode the initial subscription response JSON from server: %s"
            raw_response
        in
        assert_failure message
    | Result.Ok actual_response ->
        assert_response_equal ~context expected_response actual_response;
        return_unit


  let assert_subscription_response ~expected { context; input_channel; _ } =
    let open Lwt in
    Lwt_io.read_line input_channel
    >>= fun raw_response ->
    match parse_raw_response ~f:Subscription.Response.of_yojson raw_response with
    | Result.Error raw_response ->
        let message =
          Format.sprintf
            "Cannot decode the followup subscription response JSON from server: %s"
            raw_response
        in
        assert_failure message
    | Result.Ok actual_response ->
        assert_subscription_response_equal ~context expected actual_response;
        return_unit


  let close { input_channel; output_channel; _ } =
    let open Lwt in
    Lwt_io.close input_channel >>= fun () -> Lwt_io.close output_channel
end

module ScratchProject = struct
  type t = {
    context: test_ctxt;
    server_configuration: ServerConfiguration.t;
    watchman: Watchman.Raw.t option;
  }

  let setup
      ~context
      ?(external_sources = [])
      ?(include_typeshed_stubs = true)
      ?(include_helper_builtins = true)
      ?watchman
      sources
    =
    let add_source ~root (relative, content) =
      let content = Test.trim_extra_indentation content in
      let file = File.create ~content (Path.create_relative ~root ~relative) in
      File.write file
    in
    (* We assume that there's only one checked source directory that acts as the global root as
       well. *)
    let source_root = bracket_tmpdir context |> Path.create_absolute in
    (* We assume that there's only one external source directory. *)
    let external_root = bracket_tmpdir context |> Path.create_absolute in
    let external_sources =
      if include_typeshed_stubs then
        Test.typeshed_stubs ~include_helper_builtins () @ external_sources
      else
        external_sources
    in
    let log_root = bracket_tmpdir context |> Path.create_absolute in
    List.iter sources ~f:(add_source ~root:source_root);
    List.iter external_sources ~f:(add_source ~root:external_root);
    (* We assume that watchman root is the same as global root. *)
    let watchman_root = Option.map watchman ~f:(fun _ -> source_root) in
    let server_configuration =
      {
        ServerConfiguration.source_paths = [source_root];
        search_paths = [SearchPath.Root external_root];
        excludes = [];
        checked_directory_allowlist = [source_root];
        checked_directory_blocklist = [];
        extensions = [];
        log_path = log_root;
        global_root = source_root;
        local_root = None;
        watchman_root;
        taint_model_paths = [];
        debug = false;
        strict = false;
        show_error_traces = false;
        store_type_check_resolution = false;
        critical_files = [];
        saved_state_action = None;
        parallel = false;
        number_of_workers = 1;
      }
    in
    { context; server_configuration; watchman }


  let test_server_with
      ?(expected_exit_status = Start.ExitStatus.Ok)
      ?on_server_socket_ready
      ~f
      { context; server_configuration; watchman }
    =
    let open Lwt.Infix in
    Memory.reset_shared_memory ();
    Start.start_server
      server_configuration
      ?watchman
      ?on_server_socket_ready
      ~on_exception:(function
        | OUnitTest.OUnit_failure _ as exn ->
            (* We need to re-raise OUnit test failures since OUnit relies on it for error reporting. *)
            raise exn
        | exn ->
            Log.error "Uncaught exception: %s" (Exn.to_string exn);
            Lwt.return Start.ExitStatus.Error)
      ~on_started:(fun server_state ->
        (* Open a connection to the started server and send some test messages. *)
        let socket_address =
          let { ServerState.socket_path; _ } = !server_state in
          Lwt_unix.ADDR_UNIX (Pyre.Path.absolute socket_path)
        in
        let test_client (input_channel, output_channel) =
          f { Client.context; server_state; input_channel; output_channel }
          >>= fun () -> Lwt.return Start.ExitStatus.Ok
        in
        Lwt_io.with_connection socket_address test_client)
    >>= fun actual_exit_status ->
    assert_equal
      ~ctxt:context
      ~printer:(fun status -> Sexp.to_string (Start.ExitStatus.sexp_of_t status))
      ~cmp:[%compare.equal: Start.ExitStatus.t]
      expected_exit_status
      actual_exit_status;
    Lwt.return_unit
end
