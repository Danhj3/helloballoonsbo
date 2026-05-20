import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, errorResponse, jsonResponse } from "../_shared/cors.ts";

type AiQuoteRequest = {
  orderId?: string;
  quoteId?: string;
  notes?: string;
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") ?? "gpt-5-mini";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

async function requireStaff(req: Request) {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    throw new Error("Debes iniciar sesion para usar el asistente IA.");
  }

  const token = authHeader.replace("Bearer ", "");
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) {
    throw new Error("Sesion invalida.");
  }

  const { data: allowed, error: roleError } = await supabase.rpc("has_any_role", {
    required_roles: ["admin", "decoradora", "ventas"],
  }, {
    headers: { Authorization: authHeader },
  });

  if (roleError || !allowed) {
    throw new Error("No tienes permisos para generar cotizaciones con IA.");
  }

  return data.user;
}

async function getContext(orderId?: string, quoteId?: string) {
  const context: Record<string, unknown> = {};

  if (orderId) {
    const { data: order, error } = await supabase
      .from("orders")
      .select("id, order_number, client_name, client_phone, event_date, event_start_at, event_end_at, setup_duration_minutes, teardown_duration_minutes, load_type, desired_budget, event_type, event_address, notes, total_amount, status")
      .eq("id", orderId)
      .single();
    if (error) throw error;
    context.order = order;

    const { data: items } = await supabase
      .from("order_items")
      .select("quantity, unit_price, line_total, services(name, description, base_price)")
      .eq("order_id", orderId);
    context.orderItems = items ?? [];

    const { data: location } = await supabase
      .from("event_locations")
      .select("address_text, zone_name, access_notes")
      .eq("order_id", orderId)
      .order("created_at", { ascending: false })
      .limit(1);
    context.location = location?.[0] ?? null;
  }

  if (quoteId) {
    const { data: quote, error } = await supabase
      .from("quotes")
      .select("id, quote_number, status, material_cost, transport_cost, staff_cost, external_rental_cost, maintenance_cost, extra_cost, total_cost, target_margin, minimum_price, suggested_price, final_price, expected_profit, margin_percent, profitability_status, internal_notes")
      .eq("id", quoteId)
      .single();
    if (error) throw error;
    context.quote = quote;

    const { data: costs } = await supabase
      .from("quote_cost_items")
      .select("cost_category, description, quantity, unit_cost, line_total, notes")
      .eq("quote_id", quoteId);
    context.quoteCostItems = costs ?? [];
  }

  const { data: templates } = await supabase
    .from("quote_templates")
    .select("name, event_type, package_level, default_setup_minutes, default_teardown_minutes, default_staff_count, default_load_type, base_material_cost, base_staff_cost, base_extra_cost")
    .eq("is_active", true)
    .limit(10);
  context.templates = templates ?? [];

  const { data: inventory } = await supabase
    .from("inventory_items")
    .select("code, name, current_color, current_status, current_location, condition_notes")
    .eq("is_active", true)
    .limit(80);
  context.inventorySnapshot = inventory ?? [];

  return context;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return errorResponse("Metodo no permitido.", 405);
  }

  try {
    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
      return errorResponse("Faltan secretos de Supabase en la Edge Function.", 500);
    }
    if (!OPENAI_API_KEY) {
      return errorResponse("Falta OPENAI_API_KEY en los secretos de Supabase.", 500);
    }

    const user = await requireStaff(req);
    const body = (await req.json()) as AiQuoteRequest;
    const context = await getContext(body.orderId, body.quoteId);

    const systemInstruction = `Eres asistente operativo de Hello Balloons, un negocio de decoracion de escenarios para eventos en Bolivia. Tu tarea es aligerar la carga cognitiva de la decoradora. No inventes precios ni datos de inventario. Usa solo el contexto dado y marca informacion faltante. Respeta la regla financiera: el costo total no debe superar el 50% del precio final; si el margen es menor a 50%, advierte. Devuelve JSON valido con estas claves: resumen_pedido, informacion_faltante, riesgos, sugerencias_operativas, sugerencia_precio, mensaje_whatsapp, inventario_a_verificar.`;

    const input = [
      {
        role: "system",
        content: systemInstruction,
      },
      {
        role: "user",
        content: JSON.stringify({
          contexto: context,
          notas_adicionales: body.notes ?? "",
          instrucciones: "Organiza el pedido, detecta faltantes, revisa riesgo de margen, sugiere mensaje WhatsApp y advierte inconsistencias de inventario/color.",
        }),
      },
    ];

    const openAiResponse = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        input,
        text: {
          format: { type: "json_object" },
        },
      }),
    });

    if (!openAiResponse.ok) {
      const errorText = await openAiResponse.text();
      throw new Error(`OpenAI no pudo generar la respuesta: ${errorText}`);
    }

    const openAiPayload = await openAiResponse.json();
    const outputText = openAiPayload.output_text ?? openAiPayload.output?.flatMap((item: any) => item.content ?? []).map((content: any) => content.text ?? "").join("\n") ?? "{}";

    let aiResult: unknown;
    try {
      aiResult = JSON.parse(outputText);
    } catch {
      aiResult = { raw_text: outputText };
    }

    const { data: saved, error: saveError } = await supabase
      .from("ai_quote_outputs")
      .insert({
        order_id: body.orderId ?? null,
        quote_id: body.quoteId ?? null,
        prompt_context: context,
        ai_result: aiResult,
        model: OPENAI_MODEL,
        created_by: user.id,
      })
      .select("id, created_at")
      .single();

    if (saveError) throw saveError;

    return jsonResponse({
      id: saved.id,
      createdAt: saved.created_at,
      result: aiResult,
    });
  } catch (error) {
    return errorResponse(error instanceof Error ? error.message : "Error inesperado.", 500);
  }
});
