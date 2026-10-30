// Configuration Supabase — à renseigner avec Project Settings > API
const SUPABASE_URL = 'https://pvkwldmxmacvshxoonko.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_ISFG-v49ar1hPTF0kBR3nQ_xyuo6DzK'; // clé "anon public", jamais la service_role

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);