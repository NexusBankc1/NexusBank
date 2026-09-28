import {supabase} from './supabase.js';
import {clearMessage,routeAuthenticatedUser,setBusy,showMessage} from './auth.js';

const form=document.querySelector('#login-form');
const button=document.querySelector('#login-button');
const password=document.querySelector('#password');
const toggle=document.querySelector('#toggle-password');

const loginError=new URLSearchParams(location.search).get('error');
if(loginError==='session') showMessage('Your previous login session was not restored. Please sign in again.');

toggle?.addEventListener('click',()=>{
  const v=password.type==='text';
  password.type=v?'password':'text';
  toggle.textContent=v?'Show':'Hide';
  toggle.setAttribute('aria-pressed',String(!v));
  password.focus();
});

async function restoreSession(){
  try{
    const {data:{session},error}=await supabase.auth.getSession();
    if(error)throw error;
    if(session){
      setBusy(button,true);
      await routeAuthenticatedUser();
    }
  }catch(e){
    console.error('[NEXUS session restore]',e);
    setBusy(button,false);
  }
}

restoreSession();

form?.addEventListener('submit',async e=>{
  e.preventDefault();
  clearMessage();

  const email=document.querySelector('#email')?.value.trim();
  const pass=password?.value||'';

  if(!email||!pass){
    showMessage('Enter your email and password.');
    return;
  }

  setBusy(button,true);

  try{
    const {data,error}=await supabase.auth.signInWithPassword({email,password:pass});
    if(error)throw error;

    // Explicitly persist the returned session before navigating.
    // This prevents the next page from seeing a missing session on
    // slower Android browsers/local TrebEdit servers.
    if(!data?.session?.access_token || !data?.session?.refresh_token){
      throw new Error('Supabase did not return a valid login session.');
    }

    const {error:setSessionError}=await supabase.auth.setSession({
      access_token:data.session.access_token,
      refresh_token:data.session.refresh_token
    });
    if(setSessionError)throw setSessionError;

    // Confirm the session is readable before leaving login.html.
    const {data:{session},error:sessionError}=await supabase.auth.getSession();
    if(sessionError)throw sessionError;
    if(!session){
      throw new Error('Your login session could not be saved on this device.');
    }

    sessionStorage.setItem('nexus_login_complete','1');
    await routeAuthenticatedUser();
  }catch(e){
    const raw=String(e?.message||'').trim();
    let message=raw||'Sign-in failed. Please try again.';

    if(/invalid login credentials/i.test(raw))
      message='The email or password is incorrect.';
    else if(/email not confirmed/i.test(raw))
      message='Please confirm your email address in Supabase Authentication before signing in.';
    else if(/failed to fetch|network|fetch/i.test(raw))
      message='NEXUS could not reach Supabase. Check your internet connection and project configuration.';

    showMessage(message);
    console.error('[NEXUS login]',e);
    setBusy(button,false);
  }
});
