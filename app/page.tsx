'use client';
import {useEffect,useState} from 'react'; import {supabase} from '../lib/supabase';
type Contract={id:string;name:string;ticker:string;manager_name?:string|null;claimed_by?:string|null}; type Order={id:string;contract_id:string;side:'buy'|'sell';price_cents:number;remaining:number};
export default function Home(){const [user,setUser]=useState<any>(null),[league,setLeague]=useState<any>(null),[contracts,setContracts]=useState<Contract[]>([]),[orders,setOrders]=useState<Order[]>([]),[code,setCode]=useState(''),[name,setName]=useState(''),[teams,setTeams]=useState(''),[err,setErr]=useState(''),[claiming,setClaiming]=useState(false),[loading,setLoading]=useState(false),[creating,setCreating]=useState(false);
async function refresh(lid?:string){
 if(!lid)return;setLoading(true);
 try {
  const [l,c,o]=await Promise.all([
   supabase.from('leagues').select('*').eq('id',lid).single(),
   supabase.from('contracts').select('*').eq('league_id',lid).order('created_at'),
   supabase.from('orders').select('*').eq('league_id',lid).in('status',['open','partially_filled'])
  ]);
  if(l.error||c.error||o.error)throw l.error||c.error||o.error;
  setLeague(l.data);setContracts(c.data||[]);setOrders(o.data||[]);
 }catch(error:any){setErr(error.message)}finally{setLoading(false)}
}
async function claim(cid:string){
 if(claiming)return;setClaiming(true);setErr('');
 try{const {error}=await supabase.rpc('claim_roster_team',{p_contract:cid});if(error)setErr(error.message);await refresh(league.id)}finally{setClaiming(false)}
}
useEffect(()=>{supabase.auth.getSession().then(({data})=>setUser(data.session?.user||null));const {data}=supabase.auth.onAuthStateChange((_e,s)=>setUser(s?.user||null));return()=>data.subscription.unsubscribe()},[]);
// A Messages card remains useful on devices opening its companion web URL.
useEffect(()=>{const params=new URLSearchParams(window.location.search);const invite=params.get('invite');if(invite)setCode(invite.toUpperCase());if(!user)return;let cancelled=false;async function openLink(){if(invite){const {data,error}=await supabase.rpc('join_league',{p_invite_code:invite});if(cancelled)return;if(error){setErr(error.message);return}const expected=params.get('league');if(expected&&data.league_id.toLowerCase()!==expected.toLowerCase()){setErr('This invite does not match the linked market.');return}await refresh(data.league_id)}else if(params.get('league')){await refresh(params.get('league')!)}}void openLink();return()=>{cancelled=true}},[user?.id]);
useEffect(()=>{if(!league)return;const ch=supabase.channel('market').on('postgres_changes',{event:'*',schema:'public',table:'orders',filter:`league_id=eq.${league.id}`},()=>refresh(league.id)).on('postgres_changes',{event:'*',schema:'public',table:'trades',filter:`league_id=eq.${league.id}`},()=>refresh(league.id)).subscribe();return()=>{supabase.removeChannel(ch)}},[league?.id]);
async function login(){setErr('');let {error}=await supabase.auth.signInAnonymously({options:{data:{display_name:'Trader'}}});if(error)setErr(error.message)}
async function create(){
 if(creating)return;setErr('');
 const roster=teams.split('\n').filter(x=>x.trim()).map(x=>{const [team,manager]=x.split('|').map(v=>v.trim());return {team,manager}});
 if(roster.length<2||roster.some(x=>!x.team||!x.manager))return setErr('Add at least two rows: Team name | Manager name');
 setCreating(true);
 try{const {data,error}=await supabase.rpc('create_roster_league',{p_name:name,p_roster:roster});if(error){setErr(error.message);return}setCode(data.invite_code);await refresh(data.league_id)}
 catch(error:any){setErr(error.message)}finally{setCreating(false)}
}
async function join(){let {data,error}=await supabase.rpc('join_league',{p_invite_code:code});if(error)return setErr(error.message);refresh(data.league_id)}
async function order(cid:string,side:'buy'|'sell'){let p=Number(prompt('Limit price in cents (1-99)','25')),q=Number(prompt('Lots','100'));if(!p||!q)return;let {error}=await supabase.rpc('place_order',{p_contract:cid,p_side:side,p_price:p,p_quantity:q});if(error)setErr(error.message);else refresh(league.id)}
if(!user)return <main className="center"><div className="hero"><div className="logo">FM</div><h1>Fantasy Market</h1><p>Trade your league. Win fake money. Earn real bragging rights.</p><button onClick={login}>Enter market</button><small>Play money only · no deposits or payouts</small>{err&&<b>{err}</b>}</div></main>;
if(loading)return <main><p>Opening market…</p></main>;
if(!league)return <main><header><b>FANTASY MARKET</b><span>$10,000 starting cash</span></header><section className="panel"><h1>Start your league</h1><p>Import a screenshot in the Messages app, or enter your actual roster here.</p><label>League name<input value={name} onChange={e=>setName(e.target.value)}/></label><label>Roster: Team name | Manager name, one per line<textarea rows={8} value={teams} onChange={e=>setTeams(e.target.value)} placeholder="Team name | Manager name"/></label><button disabled={creating} onClick={create}>{creating?'Creating…':'Create market'}</button><div className="or">or join a friend's market</div><div className="row"><input placeholder="INVITE CODE" value={code} onChange={e=>setCode(e.target.value.toUpperCase())}/><button onClick={join}>Join</button></div>{err&&<b>{err}</b>}</section></main>;
const roster=contracts.filter(c=>c.manager_name);
if(roster.length&&!roster.some(c=>c.claimed_by===user.id))return <main><header><b>{league.name}</b></header><section className="panel"><h1>Which team is yours?</h1><p>Select yourself from the league roster. Each team can be claimed once.</p>{roster.map(c=><article key={c.id}><div><strong>{c.manager_name}</strong><small>{c.name}</small></div><button disabled={claiming||!!c.claimed_by} onClick={()=>claim(c.id)}>{c.claimed_by?'Claimed':'This is me'}</button></article>)}<button disabled={claiming} onClick={()=>refresh(league.id)}>Refresh available teams</button>{err&&<b role="alert">{err}</b>}</section></main>;
return <main><header><div><b>{league.name}</b><small> LIVE</small></div><span>Invite: <strong>{league.invite_code}</strong></span></header><section><h2>Championship contracts</h2><p className="muted">Price = market-implied chance. Contracts settle at $1 for the winner.</p>{contracts.map(c=>{let bid=Math.max(0,...orders.filter(o=>o.contract_id===c.id&&o.side==='buy').map(o=>o.price_cents));let asks=orders.filter(o=>o.contract_id===c.id&&o.side==='sell').map(o=>o.price_cents);let ask=asks.length?Math.min(...asks):0;return <article key={c.id}><div><strong>{c.name}</strong><small>{c.ticker}</small></div><div className="quote"><span>{bid?bid+'¢':'—'}<small>BID</small></span><span>{ask?ask+'¢':'—'}<small>ASK</small></span></div><div className="actions"><button onClick={()=>order(c.id,'buy')}>BUY</button><button className="sell" onClick={()=>order(c.id,'sell')}>SELL</button></div></article>})}</section>{err&&<div className="error">{err}</div>}<nav><span>Market</span><span>Portfolio</span><span>Leaderboard</span></nav></main>}
