// Edge Function: checar-pix
// Verifica no Mercado Pago se um pagamento Pix já foi confirmado.
// O front-end chama essa função de tempos em tempos (polling) enquanto espera o pagamento.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const ACCESS_TOKEN = Deno.env.get("MERCADO_PAGO_ACCESS_TOKEN");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { pagamentoId } = await req.json();

    if (!pagamentoId) {
      return new Response(
        JSON.stringify({ error: "ID do pagamento não informado." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!ACCESS_TOKEN) {
      return new Response(
        JSON.stringify({ error: "Access Token do Mercado Pago não configurado no servidor." }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const resposta = await fetch(`https://api.mercadopago.com/v1/payments/${pagamentoId}`, {
      headers: { "Authorization": `Bearer ${ACCESS_TOKEN}` },
    });

    const dados = await resposta.json();

    if (!resposta.ok) {
      return new Response(
        JSON.stringify({ error: "Erro ao consultar pagamento.", detalhe: dados }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // status possíveis do Mercado Pago: pending, approved, rejected, cancelled, expired
    return new Response(
      JSON.stringify({ status: dados.status, statusDetalhe: dados.status_detail }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (erro) {
    console.error("Erro inesperado:", erro);
    return new Response(
      JSON.stringify({ error: "Erro inesperado ao checar pagamento." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});