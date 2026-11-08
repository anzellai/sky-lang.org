'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const contract=require('./site-post-contract.cjs'),root=path.resolve(__dirname,'..'),policy=JSON.parse(fs.readFileSync(path.join(__dirname,'ci-site-policy.json')));
const fixture=fs.readFileSync(path.join(__dirname,'fixtures/site-blog-post-cards.html'),'utf8');
const unescape=s=>s.replaceAll('&quot;','"').replaceAll('&#x27;',"'").replaceAll('&lt;','<').replaceAll('&gt;','>').replaceAll('&amp;','&');
function fixturePage(html=fixture){
 const cards=[...html.matchAll(/<div class="post-card" data-fixture-target="([^"]+)"><span class="post-title">([^<]*)<\/span>/g)].map(m=>({target:unescape(m[1]),title:unescape(m[2])}));
 const anchors=[...html.matchAll(/<a\b[^>]*href="([^"]+)"/g)].map(m=>unescape(m[1]));
 const state={url:'/blog',title:'Blog',observed:[],clicked:[]};
 const locator=(match,click)=>({first(){return this},async waitFor(){assert(match,'FixtureSelectorAbsent')},async click(){assert(match,'FixtureSelectorAbsent');if(click)click()}});
 const page={state,cards,anchors,getByText(title,options){assert.deepEqual(options,{exact:true});const card=cards.find(c=>c.title===title);const loc=locator(card,()=>{state.url=card.target;state.title=card.title;state.clicked.push(card.target)});loc.waitFor=async()=>{assert(card,'FixtureSelectorAbsent');state.observed.push(title)};return loc},locator(selector){
  if(selector==='h1')return{async waitFor(){},async innerText(){return state.title}};
  const m=/^a\[href="([^"]+)"\]$/.exec(selector);assert(m,'UnexpectedFixtureSelector');return locator(anchors.includes(m[1]));
 },async waitForURL(url){assert.equal('https://fixture.invalid'+state.url,url,'FixtureURLMismatch')}};
 return page;
}
test('actual source metadata binds all eleven public posts',()=>{
 const posts=contract.declaredPosts(root,policy);assert.equal(posts.length,11);assert.deepEqual(posts.map(p=>p.slug),policy.sourcePostSlugs);assert.equal(new Set(posts.map(p=>p.title)).size,11);
 const source=fs.readFileSync(path.join(root,'src/View/Blog.sky'),'utf8'),row=source.slice(source.indexOf('postRow post ='),source.indexOf('-- Format a unix-ms timestamp'));
 assert(row.includes('Ui.column')&&row.includes('Ui.onClick (Navigate (BlogPost post.slug))')&&row.includes('Ui.text post.title'));assert(!row.includes('Ui.link'));
});
test('shared selector finds all eleven source cards in the public fixture',async()=>{
 const posts=contract.declaredPosts(root,policy),page=fixturePage();assert.equal(page.cards.length,11);await contract.assertPostCards(page,posts);assert.deepEqual(page.state.observed,posts.map(p=>p.title));
});
test('old actual anchor selector rejects the same clickable-column fixture',async()=>{
 const page=fixturePage();assert.equal(page.anchors.filter(a=>a.startsWith('/blog/')).length,0);
 // Exact retired production line from site-browser.cjs80, not a new search algorithm.
 const old="for(const slug of policy.sourcePostSlugs)await page.locator('a[href='+JSON.stringify('/blog/'+slug)+']').first().waitFor({state:'visible'});";
 await assert.rejects(vm.runInNewContext('(async()=>{'+old+'})()',{page,policy}),/FixtureSelectorAbsent/);
});
test('shared navigation keeps exact first slug title and same document',async()=>{
 const posts=contract.declaredPosts(root,policy),page=fixturePage();await contract.openPostCard(page,'https://fixture.invalid',posts[0],{evaluate:async()=>true});assert.deepEqual(page.state.clicked,['/blog/'+policy.sourcePostSlugs[0]]);assert.equal(page.state.title,posts[0].title);
});
test('missing any declared post still fails presence assertion',async()=>{
 const posts=contract.declaredPosts(root,policy),page=fixturePage(fixture.replace(/<div class="post-card"[^\n]+\n/,''));await assert.rejects(contract.assertPostCards(page,posts),/FixtureSelectorAbsent/);
});
test('a document replacement still fails navigation assertion',async()=>{
 const posts=contract.declaredPosts(root,policy);await assert.rejects(contract.openPostCard(fixturePage(),'https://fixture.invalid',posts[0],{evaluate:async()=>false}),/PostReload/);
});
test('source title or authority drift fails before browser execution',()=>{
 for(const field of ['title','hash']){const p=structuredClone(policy);if(field==='title')p.sourcePosts[0].title='wrong public fixture title';else p.sourceAuthority[p.sourcePosts[0].source]='0'.repeat(64);assert.throws(()=>contract.declaredPosts(root,p));}
});
test('missing source role and outside source path fail closed',()=>{
 const missing=structuredClone(policy);missing.sourcePosts.pop();assert.throws(()=>contract.declaredPosts(root,missing));
 const outside=structuredClone(policy);outside.sourcePosts[0].source='../.env';assert.throws(()=>contract.declaredPosts(root,outside));
});
test('frontmatter follows source first-key and double-quote rules',()=>{
 assert.deepEqual(contract.frontmatter('---\ntitle: "Public: title"\nslug: public\ntitle: ignored\n---\nbody'),{title:'Public: title',slug:'public'});assert.throws(()=>contract.frontmatter('not frontmatter'));assert.throws(()=>contract.frontmatter('---\ntitle: missing terminator'));
});
test('failure diagnostics contain fixed stage class and engine only',()=>{
 const e={name:'TimeoutError',get message(){throw Error('raw error message must never be read')}};
 assert.deepEqual(contract.failureSummary(e,'post-presence','chromium'),{passed:false,stage:'post-presence',engine:'chromium',errorClass:'TimeoutError'});
 assert.deepEqual(contract.failureSummary({name:'arbitrary private value'},'arbitrary private value','unbound'),{passed:false,stage:'unknown',engine:null,errorClass:'Error'});
});
