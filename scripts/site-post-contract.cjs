'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
function frontmatter(raw){
 const lines=raw.split(/\r?\n/);assert.equal(lines.shift().trim(),'---','SourcePostMetadataMismatch');const out={};let closed=false;
 for(const line of lines){if(line.trim()==='---'){closed=true;break}const i=line.indexOf(':');if(i<0)continue;const key=line.slice(0,i).trim();let value=line.slice(i+1).trim();if(value.length>=2&&value.startsWith('"')&&value.endsWith('"'))value=value.slice(1,-1);if(!Object.hasOwn(out,key))out[key]=value}
 assert(closed,'SourcePostMetadataMismatch');return out;
}
function declaredPosts(root,policy){
 assert(Array.isArray(policy.sourcePosts)&&policy.sourcePosts.length===policy.sourcePostSlugs.length&&policy.sourcePosts.length>0,'SourcePostInventoryMismatch');
 assert.deepEqual(policy.sourcePosts.map(p=>p.slug),policy.sourcePostSlugs,'SourcePostInventoryMismatch');
 const sources=policy.sourcePosts.map(p=>p.source);assert.equal(new Set(sources).size,sources.length,'SourcePostInventoryMismatch');
 const actual=fs.readdirSync(path.join(root,'content/posts')).filter(n=>n.endsWith('.md')).map(n=>'content/posts/'+n).sort();assert.deepEqual([...sources].sort(),actual,'SourcePostInventoryMismatch');
 for(const p of policy.sourcePosts){
  assert(typeof p.source==='string'&&/^content\/posts\/[A-Za-z0-9][A-Za-z0-9._-]*\.md$/.test(p.source),'SourcePostAuthorityMismatch');assert(typeof p.slug==='string'&&/^[a-z0-9][a-z0-9-]*$/.test(p.slug)&&typeof p.title==='string'&&p.title.trim(),'SourcePostMetadataMismatch');
  const file=path.join(root,p.source),kind=fs.lstatSync(file);assert(kind.isFile()&&!kind.isSymbolicLink(),'SourcePostAuthorityMismatch');const bytes=fs.readFileSync(file);assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),policy.sourceAuthority[p.source],'SourcePostAuthorityMismatch');const parsed=frontmatter(bytes.toString('utf8'));assert.equal(parsed.slug,p.slug,'SourcePostMetadataMismatch');assert.equal(parsed.title,p.title,'SourcePostMetadataMismatch');
 }
 assert.equal(new Set(policy.sourcePosts.map(p=>p.title)).size,policy.sourcePosts.length,'SourcePostTitlesAmbiguous');return policy.sourcePosts;
}
function cardTitle(page,post){return page.getByText(post.title,{exact:true}).first()}
async function assertPostCards(page,posts){for(const post of posts)await cardTitle(page,post).waitFor({state:'visible'})}
async function openPostCard(page,base,post,realm){
 await cardTitle(page,post).click();await page.waitForURL(base+'/blog/'+post.slug);await page.locator('h1').waitFor();assert(await realm.evaluate(x=>x.global===globalThis&&x.document===document),'PostReload');assert.equal(await page.locator('h1').innerText(),post.title,'PostTitleMismatch');
}
const STAGES=new Set(['arguments','source-authority','build-info-before','browser-launch','page-load','hydration','home-capabilities','blog-navigation','post-presence','post-navigation','widths','browser-errors-and-policy','build-info-after','report']);
function failureSummary(error,stage,engine){return{passed:false,stage:STAGES.has(stage)?stage:'unknown',engine:['chromium','webkit'].includes(engine)?engine:null,errorClass:['AssertionError','TimeoutError','TypeError','Error'].includes(error&&error.name)?error.name:'Error'}}
module.exports={frontmatter,declaredPosts,assertPostCards,openPostCard,failureSummary};
