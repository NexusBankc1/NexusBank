import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

export const SUPABASE_URL = 'https://uzsjjdkvqdqndxapkluz.supabase.co';
export const SUPABASE_ANON_KEY = 'sb_publishable_z79qq5tGH14Bptpwc5pY6Q_GY8uTNZo';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
    flowType: 'implicit'
  }
});

export async function currentUser(){
  const {data:{user}, error} = await supabase.auth.getUser();
  if(error) throw error;
  return user || null;
}

export async function signOut(){
  await supabase.auth.signOut();
  location.replace('login.html');
}

export function money(value,currency='USD'){
  return `${Number(value||0).toLocaleString(undefined,{minimumFractionDigits:2,maximumFractionDigits:2})} ${currency}`.trim();
}

export function escapeHtml(v=''){
  return String(v).replace(/[&<>\'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
}

export function formatDate(v){
  const d=new Date(v);
  return Number.isNaN(d.getTime())?'—':d.toLocaleString(undefined,{dateStyle:'medium',timeStyle:'short'});
}

// Login/admin routing uses a SECURITY DEFINER RPC so it cannot be broken
// by recursive profiles RLS policies.
export async function profileFor(userId){
  if(!userId) return null;
  const {data,error}=await supabase.rpc('nexus_get_my_profile');
  if(error) throw error;
  const row=Array.isArray(data)?data[0]:data;
  if(!row || row.id!==userId) return null;
  return row;
}

export async function accountForUser(userId){
  const {data,error}=await supabase.from('accounts').select('*').eq('user_id',userId).is('deleted_at',null).limit(1).maybeSingle();
  if(error)throw error;
  return data;
}

export function profileIsActive(p){
  if(!p) return false;
  if(typeof p.is_active === 'boolean') return p.is_active;
  if(p.status === 'deactivated') return false;
  if(p.status === 'active') return true;
  return true;
}

export function profileIsDeleted(p){ return !!p?.deleted_at; }

export async function enforceAccountAccess(user){
  const p=await profileFor(user.id).catch(()=>null);
  if(!p) return {profile:null,account:null,allowed:false};
  if(!profileIsActive(p) || profileIsDeleted(p)) return {profile:p,account:null,allowed:false,reason:'deactivated'};
  const a=await accountForUser(user.id).catch(()=>null);
  return {profile:p,account:a,allowed:true};
}

export async function invokeAdminFunction(action,payload={}){
  const {data,error}=await supabase.functions.invoke('nexus-admin',{body:{action,...payload}});
  if(error) throw error;
  if(data?.error) throw new Error(data.error);
  return data;
}
