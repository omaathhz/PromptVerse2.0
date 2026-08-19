// supabase/functions/cakto-webhook/index.ts
// Deploy:  supabase functions deploy cakto-webhook --no-verify-jwt
// Segredos: supabase secrets set CAKTO_SECRET=xxx SUPABASE_URL=xxx SUPABASE_SERVICE_ROLE_KEY=xxx
//
// URL para colar no painel da Cakto:
// https://SEU-PROJETO.supabase.co/functions/v1/cakto-webhook

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, // service_role ignora RLS
  { auth: { persistSession: false } }
);

const CAKTO_SECRET = Deno.env.get("CAKTO_SECRET")!;

// confere a assinatura do webhook (HMAC SHA-256)
async function assinaturaValida(body: string, assinatura: string | null) {
  if (!assinatura) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(CAKTO_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const esperado = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return esperado === assinatura.replace(/^sha256=/, "").toLowerCase();
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const raw = await req.text();

  // 1. segurança: só aceita evento assinado pela Cakto
  const ok = await assinaturaValida(raw, req.headers.get("x-cakto-signature"));
  if (!ok) return new Response("Assinatura inválida", { status: 401 });

  const evento = JSON.parse(raw);

  // 2. normaliza os campos (ajuste os nomes conforme o payload real da Cakto)
  const eventId   = evento.id ?? evento.event_id ?? crypto.randomUUID();
  const eventType = evento.event ?? evento.type;            // purchase_approved | refund | ...
  const orderId   = evento.data?.order_id ?? evento.order_id;
  const email     = (evento.data?.customer?.email ?? evento.customer_email ?? "").toLowerCase();
  const nome      = evento.data?.customer?.name ?? evento.customer_name ?? null;
  const offerId   = String(evento.data?.offer?.id ?? evento.offer_id ?? "");

  if (!email) return new Response("Evento sem e-mail", { status: 400 });

  // 3. processa a compra
  let { data, error } = await supabase.rpc("process_cakto_purchase", {
    p_event_id: eventId,
    p_event_type: eventType,
    p_order_id: orderId,
    p_email: email,
    p_offer_id: offerId,
    p_payload: evento,
  });
  if (error) return new Response(error.message, { status: 500 });

  // 4. comprador novo: cria a conta no Auth e processa de novo
  if (data?.status === "user_not_found") {
    const { error: erroCriacao } = await supabase.auth.admin.createUser({
      email,
      email_confirm: true,
      user_metadata: { name: nome },
    });
    if (erroCriacao) return new Response(erroCriacao.message, { status: 500 });

    ({ data, error } = await supabase.rpc("process_cakto_purchase", {
      p_event_id: eventId + "-retry",
      p_event_type: eventType,
      p_order_id: orderId,
      p_email: email,
      p_offer_id: offerId,
      p_payload: evento,
    }));
    if (error) return new Response(error.message, { status: 500 });

    // 5. e-mail de definição de senha (o comprador cria a própria senha)
    await supabase.auth.admin.generateLink({
      type: "recovery",
      email,
      options: { redirectTo: "https://SEUDOMINIO.com.br/definir-senha" },
    });
  }

  return new Response(JSON.stringify(data), {
    headers: { "content-type": "application/json" },
  });
});
