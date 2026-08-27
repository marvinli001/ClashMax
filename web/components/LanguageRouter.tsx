import { LANG_STORAGE_KEY, localePath } from '@/lib/site'

/**
 * First-visit language routing, run before first paint.
 *
 * English is canonical, so only `/` redirects: a visitor whose browser asks
 * for Chinese, or who chose Chinese here before, is sent to `/zh/`. A direct
 * link to `/zh/` is always honoured, and a session flag stops the two pages
 * from ever handing a visitor back and forth.
 *
 * This runs synchronously in <head>, so the wrong language never paints.
 */
const script = `(function(){try{
var K=${JSON.stringify(LANG_STORAGE_KEY)},G=K+'-routed',Z=${JSON.stringify(localePath('zh'))};
if(sessionStorage.getItem(G))return;
var c=localStorage.getItem(K),t=c==='en'||c==='zh'?c:null;
if(!t){var l=navigator.languages&&navigator.languages.length?navigator.languages:[navigator.language||'en'];
for(var i=0;i<l.length;i++){var s=String(l[i]).toLowerCase();
if(s.indexOf('zh')===0){t='zh';break}if(s.indexOf('en')===0){t='en';break}}}
if(t==='zh'){sessionStorage.setItem(G,'1');location.replace(Z+location.search+location.hash)}
}catch(e){}})();`

export function LanguageRouter() {
  return <script dangerouslySetInnerHTML={{ __html: script }} />
}
