const sc = require('/lib/sc_js_binding');
const __fs = require('fs');
const request = require('request');
const assert = require('assert');

function SendRequest(url, body) {
    // console.log('sending request to url: ' + url);
    return new Promise(function(resolve, reject) {
        request({
            'url': url,
            'method': 'POST',
            'json': true,
            'body': body
        }, function (error, response, body) {
            if(error) {
                reject(error);
            }
            // console.log('device resp: ' + JSON.stringify(body));
            let json = JSON.stringify(body);
            json = json.replace('hostname', '127.0.0.1');
            resolve(JSON.parse(json));
        });

    });
}

eval(__fs.readFileSync('/func/prewarm.js') + '');

if (process.argv[2] == '--sc-snapshot') {
  sc.sc_snapshot();
}

fn_code = __fs.readFileSync('/func/execute.js') + '';

t_attest_after_import = sc.stat_get_stat(0x3);
t_import_done = Date.now() / 1000;

n_hcalls_before_exec = sc.stat_get_stat(0x1);
t_encrypt_before_exec = sc.stat_get_stat(0x4);
t_grant_before_exec = sc.stat_get_stat(0x5);
t_delegate_before_exec = sc.stat_get_stat(0x6);
eval(fn_code);

SendRequest('http://127.0.0.1:8888/get_param', {
  "fn_name": fn_name,
}).then((param) => {
  handler(param).then((retval) => {
    SendRequest('http://127.0.0.1:8888/set_retval', {
      "fn_name": fn_name,
      "retval": retval,
    }).then((body) =>{
      assert(body == 'OK');
  
      n_hcalls_after_exec = sc.stat_get_stat(0x1);
      t_encrypt_after_exec = sc.stat_get_stat(0x4);
      t_grant_after_exec = sc.stat_get_stat(0x5);
      t_delegate_after_exec = sc.stat_get_stat(0x6);
      n_cow = sc.stat_get_stat(0x2);
      t_func_done = Date.now() / 1000;
      console.log(`t_import_done ${t_import_done}`);
      console.log(`t_func_done ${t_func_done}`);
      if (n_hcalls_before_exec >= 0) {
            console.log(`n_hcalls_exec ${n_hcalls_after_exec - n_hcalls_before_exec}`);
            console.log(`t_encrypt_exec ${t_encrypt_after_exec - t_encrypt_before_exec}`);
            console.log(`t_grant_exec ${t_grant_after_exec - t_grant_before_exec}`);
            console.log(`t_delegate_exec ${t_delegate_after_exec - t_delegate_before_exec}`);
            console.log(`t_attest_import ${t_attest_after_import}`);
            console.log(`t_grant_import ${t_grant_before_exec}`);
            console.log(`t_delegate_import ${t_delegate_before_exec}`);
            console.log(`n_cow ${n_cow}`);
      }
    })
  })  
});

// handler(param).then(() => {
//   n_hcalls_after_exec = sc.stat_get_n_hcalls();
//   t_func_done = Date.now() / 1000;
//   console.log(`t_import_done ${t_import_done}`);
//   console.log(`t_func_done ${t_func_done}`);
//   if (n_hcalls_before_exec >= 0) {
//         console.log(`n_hcalls_exec ${n_hcalls_after_exec - n_hcalls_before_exec}`);
//   }
// });
