// Edge Function: criar-pix
// Recebe o valor do pedido e gera uma cobrança Pix dinâmica no Mercado Pago.
// O Access Token NUNCA é exposto ao front-end — fica só aqui, como variável de ambiente.
 
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
 
const ACCESS_TOKEN = Deno.env.get("MERCADO_PAGO_ACCESS_TOKEN");
 
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
 
serve(async (req) => {
  // Responde à verificação de CORS do navegador
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
 
  try {
    const { valor, descricao, slugLoja, pedidoId, emailPagador } = await req.json();
 
    if (!valor || valor <= 0) {
      return new Response(
        JSON.stringify({ error: "Valor inválido." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
 
    if (!ACCESS_TOKEN) {
      return new Response(
        JSON.stringify({ error: "Access Token do Mercado Pago não configurado no servidor." }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
 
    // Cria a cobrança Pix no Mercado Pago
    const resposta = await fetch("https://api.mercadopago.com/v1/payments", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${ACCESS_TOKEN}`,
        "Content-Type": "application/json",
        "X-Idempotency-Key": `${slugLoja}-${pedidoId}-${Date.now()}`,
      },
      body: JSON.stringify({
        transaction_amount: Number(valor),
        description: descricao || "Pedido FH Cardápio",
        payment_method_id: "pix",
        payer: {
          email: emailPagador || "cliente@fhcardapio.com.br",
        },
        // Esse campo é só pra rastreabilidade nossa, não afeta o pagamento
        external_reference: `${slugLoja}-${pedidoId}`,
      }),
    });
 
    const dadosPagamento = await resposta.json();
 
    if (!resposta.ok) {
      console.error("Erro do Mercado Pago:", dadosPagamento);
      return new Response(
        JSON.stringify({ error: "Erro ao gerar Pix.", detalhe: dadosPagamento }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
 
    const pix = dadosPagamento.point_of_interaction?.transaction_data;
 
    return new Response(
      JSON.stringify({
        id: dadosPagamento.id,
        status: dadosPagamento.status,
        qrCodeBase64: pix?.qr_code_base64,
        qrCodeTexto: pix?.qr_code,
        expiraEm: dadosPagamento.date_of_expiration,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
 
  } catch (erro) {
    console.error("Erro inesperado:", erro);
    return new Response(
      JSON.stringify({ error: "Erro inesperado ao gerar Pix." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});