
open OUnit
open TestCommon

let tests = 
  "API" >::
  bracket_oasis_db
    (* Pre start *)
    ignore

    (* Main *)
    (fun ocs ->
       let base_url = 
         ocs.ocs_base_url^"api"
       in
       let ctxt = 
         !odb 
       in

       (* Upload a package *)
       let () = 
         ODBCurl.with_curl
           (fun curl ->
              let write_fun = String.length in

                Curl.set_verbose curl !verbose; 
                Curl.set_followlocation curl true;
                Curl.set_failonerror curl true;

                Curl.set_writefunction curl write_fun;

                (* Login *)
                Curl.set_url curl (base_url^"/login?login=admin1&password=");
                Curl.set_cookiefile curl ""; (* Enabled in-memory cookie *)
                Curl.perform curl;

                (* Upload *)
                Curl.set_url curl (base_url^"/upload");
                Curl.set_post curl true;
                Curl.set_httppost curl
                  [Curl.CURLFORM_CONTENT("publink", "toto", Curl.DEFAULT);
                   Curl.CURLFORM_FILE("tarball", 
                                      in_data_dir "ocaml-moifile-0.1.0.tar.gz",
                                      Curl.DEFAULT)];
                Curl.perform curl;

                (* Logout *)
                Curl.set_url curl (base_url^"/logout");
                Curl.set_post curl false;
                Curl.perform curl)
       in

       let lst = 
         ODBREST.Pkg.list ~ctxt base_url ()
       in
       let lst' = 
         List.map 
           (fun pkg ->
              pkg.ODBPkg.pkg_name,
              OASISVersion.string_of_version 
                (ODBREST.PkgVer.latest ~ctxt base_url pkg.ODBPkg.pkg_name))
           lst
       in
         assert_equal 
           ~msg:"list of latest packages"
           ~printer:(fun lst -> 
                       ("["^(String.concat "; " 
                               (List.map 
                                  (fun (p, v) -> 
                                     p^", "^v)
                                  lst))^"]"))
           ["ocaml-moifile", "0.1.0"]
           lst')

    (* Post stop *)
    ignore
