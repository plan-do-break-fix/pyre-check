(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open OUnit2
open Ast
open Core
open Test

let test_collection context =
  let assert_collected_names ~expected source_text =
    let source = parse ~handle:"test.py" source_text in
    let actual =
      UnannotatedGlobal.Collector.from_source source
      |> List.map ~f:(fun { UnannotatedGlobal.Collector.Result.name; _ } -> name)
    in
    assert_equal
      ~ctxt:context
      ~cmp:[%compare.equal: Reference.t list]
      ~printer:(List.to_string ~f:Reference.show)
      expected
      actual
  in

  assert_collected_names
    {|
       x = 1
       y = 2
       z = 3
    |}
    ~expected:[!&"test.x"; !&"test.y"; !&"test.z"];
  assert_collected_names
    {|
      x, y = 1, 2
      z[3] = 4
      u, (v, w) = derp
    |}
    ~expected:[!&"test.x"; !&"test.y"];
  assert_collected_names
    {|
       def foo(): pass
       def bar(): pass
       def foo(): pass
    |}
    ~expected:[!&"foo"; !&"bar"; !&"foo"];
  assert_collected_names
    {|
       import x
       import y as z
       from u.v import w
       from a.b import c as d
    |}
    ~expected:[!&"test.x"; !&"test.z"; !&"test.w"; !&"test.d"];
  assert_collected_names
    {|
       if derp():
         x = 1
         z = 2
       else:
         x = 3
         y = 4
    |}
    ~expected:[!&"test.x"; !&"test.z"; !&"test.x"; !&"test.y"];
  assert_collected_names
    {|
       try:
         x = 1
         z = 2
       except:
         y = 3
    |}
    ~expected:[!&"test.x"; !&"test.z"; !&"test.y"];
  ()


let () = "node" >::: ["collection" >:: test_collection] |> Test.run
