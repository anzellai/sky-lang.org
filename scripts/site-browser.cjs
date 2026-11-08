const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..'),policy=JSON.parse(fs.readFileSync(path.join(__dirname,'ci-site-policy.json')));
const {declaredPosts,assertPostCards,openPostCard,failureSummary}=require('./site-post-contract.cjs');
let assets=new Set(),stage='arguments',activeEngine=null;
function allowed(method,url,base){
 const u=new URL(url,base),b=new URL(base);
 if(['data:','blob:','about:'].includes(u.protocol))return method==='GET'||method==='HEAD';
 if(!['http:','https:'].includes(u.protocol)||u.origin!==b.origin)return false;
 if(method==='POST')return policy.readonlyRpcPaths.includes(u.pathname);
 if(!['GET','HEAD'].includes(method))return false;
 return ['/', '/blog','/healthz','/_sky/buildinfo','/robots.txt','/sitemap.xml'].includes(u.pathname)||policy.sourcePostSlugs.some(x=>u.pathname==='/blog/'+x)||assets.has(u.pathname);
}
function allowedResponse(status){return Number.isInteger(status)&&status>=100&&status<=599&&(!(status>=300&&status<400)||status===304)}
async function guardRoute(route,base,state){
 const request=route.request();
 if(!allowed(request.method(),request.url(),base)){state.denied++;return route.abort('blockedbyclient')}
 if(request.method()==='POST')state.readonlyRpc++;
 if(['data:','blob:','about:'].includes(new URL(request.url()).protocol))return route.continue();
 // A route handler alone covers only the first URL of a redirect chain.
 // Never let the API client or browser follow an unproven redirect.
 const response=await route.fetch({maxRedirects:0});
 if(!allowedResponse(response.status())){state.denied++;return route.abort('blockedbyclient')}
 return route.fulfill({response});
}
async function policyTests(){
 const base='https://fixture.invalid';let count=0;const test=f=>{f();count++};
 test(()=>assert.deepEqual(policy.readonlyRpcPaths,['/_rpc/SpaInit_','/_rpc/LoadPosts']));
 for(const p of ['/_rpc/EditorPublish','/_rpc/EditorSaveDraft','/_rpc/ConfirmDelete','/_rpc/LoadEditPost','/_rpc/Unknown'])test(()=>assert(!allowed('POST',base+p,base)));
 for(const p of ['/auth/callback','/admin','/internal/process'])test(()=>assert(!allowed('GET',base+p,base)));
 test(()=>assert(!allowed('GET','https://foreign.invalid/',base)));test(()=>assert(allowed('POST',base+'/_rpc/LoadPosts',base)));
 for(const status of [301,302,303,307,308]){
  let fetched=0,aborted=0,fulfilled=0;await guardRoute({request:()=>({method:()=> 'GET',url:()=>base+'/'}),fetch:async opts=>{assert.deepEqual(opts,{maxRedirects:0});fetched++;return{status:()=>status}},abort:async()=>{aborted++},fulfill:async()=>{fulfilled++}},base,{denied:0,readonlyRpc:0});test(()=>assert.deepEqual([fetched,aborted,fulfilled],[1,1,0]));
 }
 for(const status of [200,304])test(()=>assert(allowedResponse(status)));
 console.log(JSON.stringify({passed:true,checks:count,networkRequests:0,browserLaunches:0}));
}
async function redirectIntegration(pw){
 const http=require('node:http');let foreignHits=0,sourceHits=0;const results=[];
 const foreign=http.createServer((q,r)=>{foreignHits++;r.end('<!doctype html><title>foreign fixture</title>')});
 const origin=http.createServer((q,r)=>{const status=Number(new URL(q.url,'http://fixture.invalid').searchParams.get('status'));if(![301,302,303,307,308].includes(status)){r.writeHead(404);r.end();return}sourceHits++;r.writeHead(status,{Location:'http://127.0.0.1:'+foreign.address().port+'/foreign'});r.end()});
 const listen=server=>new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve)});
 const close=server=>new Promise(resolve=>{if(!server.listening)return resolve();server.close(resolve);server.closeAllConnections()});
 try{
  await listen(foreign);await listen(origin);const base='http://127.0.0.1:'+origin.address().port;
  for(const [name,engine] of Object.entries(pw)){
   const browser=await engine.launch({headless:true});
   try{
    for(const status of [301,302,303,307,308]){
     const context=await browser.newContext({serviceWorkers:'block'}),state={denied:0,readonlyRpc:0};
     try{
      await context.route('**/*',route=>guardRoute(route,base,state));const page=await context.newPage();sourceHits=0;foreignHits=0;let rejected=false;
      try{await page.goto(base+'/?status='+status,{waitUntil:'load',timeout:10000})}catch{rejected=true}
      assert.equal(sourceHits,1,'RedirectFixtureNotReached');assert.equal(foreignHits,0,'ForeignRedirectWasFollowed');assert.equal(state.denied,1,'RedirectNotDenied');assert(rejected,'RedirectNavigationNotAborted');
      results.push({engine:name,status,passed:true,sourceHits,foreignHits});
     }finally{await context.close()}
    }
   }finally{await browser.close()}
  }
 }finally{await close(origin);await close(foreign)}
 assert.equal(results.length,10);return{passed:true,checks:results.length,foreignServerHits:0,publicFixtureOnly:true};
}
function arg(n){const i=process.argv.indexOf(n);assert(i>=0&&process.argv[i+1]);return process.argv[i+1]}
async function main(){
 const base=arg('--base'),facts=JSON.parse(fs.readFileSync(arg('--facts'),'utf8')),out=arg('--out'),production=process.argv.includes('--production');
 const parsedBase=new URL(base);assert(production?base===policy.base:parsedBase.protocol==='http:'&&parsedBase.hostname==='127.0.0.1'&&parsedBase.port!==''&&base===parsedBase.origin);
 stage='source-authority';const posts=declaredPosts(root,policy);
 for(const [p,h]of Object.entries(policy.sourceAuthority))assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(root,p))).digest('hex'),h,'ReadOnlySourceDrift');
 assets=new Set(Object.keys(facts.files).filter(x=>x.startsWith('frontend/dist/')).map(x=>'/'+x.slice('frontend/dist/'.length)));
 assert.match(facts.sourceCommit,/^[0-9a-f]{40}$/,'SourceCommitFormat');
 async function observed(){const r=await fetch(base+'/_sky/buildinfo',{redirect:'manual'});assert.equal(r.status,200,'BuildInfoHTTP');const info=await r.json();assert.match(info.commit||'',/^[0-9a-f]{7,40}$/,'ObservedCommitFormat');assert(facts.sourceCommit.startsWith(info.commit),'ObservedSourceMismatch');assert(/(?<![0-9])0\.29\.4(?![0-9])/.test(info.skyVersion||''),'ObservedCompilerMismatch')}
 const {chromium,webkit}=require('../e2e/node_modules/playwright'),results=[];
 for(const [engine,type]of Object.entries({chromium,webkit})){
  activeEngine=engine;stage='build-info-before';await observed();stage='browser-launch';const browser=await type.launch({headless:true});try{
   const context=await browser.newContext({serviceWorkers:'block'}),state={denied:0,readonlyRpc:0};let errors=0,wasm=0;
   try{
    await context.route('**/*',r=>guardRoute(r,base,state));if(context.routeWebSocket)await context.routeWebSocket('**/*',ws=>{state.denied++;ws.close()});
    const page=await context.newPage();page.on('pageerror',()=>errors++);page.on('response',r=>{if(new URL(r.url()).pathname.endsWith('.wasm')&&[200,304].includes(r.status()))wasm++});
    await page.addInitScript(()=>{const observer=new MutationObserver(()=>{if(!document.documentElement.hasAttribute('data-sky-hydrating'))window.__websiteHydrated=true});observer.observe(document,{subtree:true,attributes:true,attributeFilter:['data-sky-hydrating']})});
    stage='page-load';const response=await page.goto(base+'/',{waitUntil:'domcontentloaded'});assert.equal(response.status(),200);stage='hydration';await page.waitForFunction(()=>window.__websiteHydrated===true,null,{timeout:10000});assert(wasm>0,'WasmNotLoaded');
    stage='home-capabilities';const text=await page.locator('body').innerText();for(const label of ['Less repeated SPA work','Scroll after a step renders'])assert(text.includes(label),'HomeCapabilityMissing');
    stage='blog-navigation';const realm=await page.evaluateHandle(()=>({global:globalThis,document}));await page.locator('a[href="/blog"]').first().click();await page.waitForURL(base+'/blog');await page.locator('h1').waitFor();assert(await realm.evaluate(x=>x.global===globalThis&&x.document===document),'BlogReload');
    stage='post-presence';await assertPostCards(page,posts);
    stage='post-navigation';await openPostCard(page,base,posts[0],realm);await realm.dispose();
    stage='widths';for(const width of [390,820,1180,1440]){await page.setViewportSize({width,height:960});await page.waitForTimeout(300);assert(!await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1),'HorizontalOverflow')}
    stage='browser-errors-and-policy';assert.equal(errors,0,'PageErrors');assert.equal(state.denied,0,'UnexpectedOrMutatingRequest');results.push({engine,passed:true,hydration:true,sameDocumentBlogAndPost:true,sourcePosts:policy.sourcePostSlugs.length,widths:4,readonlyRpcRequests:state.readonlyRpc,formsSubmitted:0});
   }finally{await context.close();assert.equal(state.denied,0,'RequestDuringClose')}
  }finally{await browser.close()}
  stage='build-info-after';await observed();
 }
 stage='report';fs.mkdirSync(path.dirname(out),{recursive:true});fs.writeFileSync(out,JSON.stringify({passed:true,production,results},null,2)+'\n',{flag:'wx',mode:0o600});console.log(JSON.stringify({passed:true,browserComparisons:2,production,formsSubmitted:0}));
}
if(process.argv.includes('--policy-self-test'))policyTests().catch(()=>{console.error('PolicyFixtureFailed');process.exitCode=1});
else if(process.argv.includes('--redirect-integration')){const {chromium,webkit}=require('../e2e/node_modules/playwright');redirectIntegration({chromium,webkit}).then(x=>console.log(JSON.stringify(x))).catch(()=>{console.error('RedirectFixtureFailed');process.exitCode=1})}
else main().catch(error=>{const summary=failureSummary(error,stage,activeEngine);const i=process.argv.indexOf('--out');if(i>=0&&process.argv[i+1]){try{const dest=process.argv[i+1]+'.failure.json';fs.mkdirSync(path.dirname(dest),{recursive:true});fs.writeFileSync(dest,JSON.stringify(summary)+'\n',{flag:'wx',mode:0o600})}catch{}}console.error(JSON.stringify(summary));process.exitCode=1});
