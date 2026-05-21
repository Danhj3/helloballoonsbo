import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders, errorResponse, jsonResponse } from "../_shared/cors.ts";

type LoadType = "light" | "medium" | "heavy";

type TransportRequest = {
  orderId?: string;
  quoteId?: string;
  origin?: {
    latitude: number;
    longitude: number;
  };
  destination?: {
    addressText?: string;
    latitude?: number;
    longitude?: number;
    zoneName?: string;
    mapsUrl?: string;
  };
  mapsUrl?: string;
  addressText?: string;
  loadType?: LoadType;
  useGoogleRoutes?: boolean;
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const GOOGLE_MAPS_API_KEY = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function toRad(value: number) {
  return (value * Math.PI) / 180;
}

function haversineKm(a: { latitude: number; longitude: number }, b: { latitude: number; longitude: number }) {
  const radiusKm = 6371;
  const dLat = toRad(b.latitude - a.latitude);
  const dLon = toRad(b.longitude - a.longitude);
  const lat1 = toRad(a.latitude);
  const lat2 = toRad(b.latitude);
  const x = Math.sin(dLat / 2) ** 2 + Math.sin(dLon / 2) ** 2 * Math.cos(lat1) * Math.cos(lat2);
  return 2 * radiusKm * Math.asin(Math.sqrt(x));
}

function roundToStep(value: number, step: number) {
  if (!step || step <= 0) return Math.round(value);
  return Math.ceil(value / step) * step;
}

function validCoordinate(latitude: number, longitude: number) {
  return Number.isFinite(latitude) && Number.isFinite(longitude) && Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180;
}

function parseCoordinates(value: string) {
  const input = value.trim();
  const decoded = (() => {
    try { return decodeURIComponent(input); } catch { return input; }
  })();

  const patterns = [
    /@(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/,
    /!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/,
    /[?&]q=(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/,
    /[?&]query=(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/,
    /(-?\d{1,2}\.\d{4,}),\s*(-?\d{1,3}\.\d{4,})/,
  ];

  for (const pattern of patterns) {
    const match = decoded.match(pattern);
    if (match) {
      const latitude = Number(match[1]);
      const longitude = Number(match[2]);
      if (validCoordinate(latitude, longitude)) return { latitude, longitude };
    }
  }

  return null;
}

async function resolveMapsUrl(mapsUrl: string) {
  const local = parseCoordinates(mapsUrl);
  if (local) return { ...local, resolvedUrl: mapsUrl, resolution: "parsed_original_url" };

  const response = await fetch(mapsUrl, {
    method: "GET",
    redirect: "follow",
    headers: {
      "User-Agent": "HelloBalloonsBot/1.0",
    },
  });

  const resolvedUrl = response.url || mapsUrl;
  const parsedResolved = parseCoordinates(resolvedUrl);
  if (parsedResolved) return { ...parsedResolved, resolvedUrl, resolution: "parsed_redirect_url" };

  const html = await response.text();
  const parsedHtml = parseCoordinates(html);
  if (parsedHtml) return { ...parsedHtml, resolvedUrl, resolution: "parsed_html" };

  throw new Error("No se pudieron extraer coordenadas del link de Google Maps. Abre el link, copia el enlace largo o pega coordenadas visibles.");
}

async function geocodeAddress(addressText: string) {
  if (!GOOGLE_MAPS_API_KEY) return null;
  const url = new URL("https://maps.googleapis.com/maps/api/geocode/json");
  url.searchParams.set("address", addressText);
  url.searchParams.set("key", GOOGLE_MAPS_API_KEY);
  url.searchParams.set("language", "es");
  url.searchParams.set("region", "bo");

  const response = await fetch(url.toString());
  if (!response.ok) throw new Error("No se pudo geocodificar la direccion.");
  const payload = await response.json();
  const location = payload.results?.[0]?.geometry?.location;
  if (!location) return null;
  return {
    latitude: Number(location.lat),
    longitude: Number(location.lng),
    formattedAddress: payload.results?.[0]?.formatted_address,
    providerPayload: payload,
  };
}

async function getDefaultOrigin() {
  const { data, error } = await supabase
    .from("business_locations")
    .select("id, latitude, longitude, address_text")
    .eq("is_default", true)
    .eq("is_active", true)
    .single();

  if (error || !data?.latitude || !data?.longitude) {
    throw new Error("Configura la base de salida de Hello Balloons con latitud y longitud.");
  }

  return {
    id: data.id as string,
    latitude: Number(data.latitude),
    longitude: Number(data.longitude),
    addressText: data.address_text as string | null,
  };
}

async function getDefaultRates() {
  const { data, error } = await supabase
    .from("transport_rate_profiles")
    .select("id, base_fee, cost_per_km_roundtrip, cost_per_minute, light_load_surcharge, medium_load_surcharge, heavy_load_surcharge, safety_margin, rounding_step")
    .eq("is_default", true)
    .eq("is_active", true)
    .single();

  if (error || !data) {
    throw new Error("Configura una tarifa de transporte activa.");
  }

  return {
    id: data.id as string,
    baseFee: Number(data.base_fee ?? 0),
    costPerKmRoundtrip: Number(data.cost_per_km_roundtrip ?? 0),
    costPerMinute: Number(data.cost_per_minute ?? 0),
    lightLoadSurcharge: Number(data.light_load_surcharge ?? 0),
    mediumLoadSurcharge: Number(data.medium_load_surcharge ?? 0),
    heavyLoadSurcharge: Number(data.heavy_load_surcharge ?? 0),
    safetyMargin: Number(data.safety_margin ?? 0),
    roundingStep: Number(data.rounding_step ?? 10),
  };
}

async function getGoogleRoute(origin: { latitude: number; longitude: number }, destination: { latitude: number; longitude: number }) {
  if (!GOOGLE_MAPS_API_KEY) return null;

  const response = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY,
      "X-Goog-FieldMask": "routes.distanceMeters,routes.duration,routes.staticDuration",
    },
    body: JSON.stringify({
      origin: { location: { latLng: { latitude: origin.latitude, longitude: origin.longitude } } },
      destination: { location: { latLng: { latitude: destination.latitude, longitude: destination.longitude } } },
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_AWARE",
      computeAlternativeRoutes: false,
      languageCode: "es-419",
      units: "METRIC",
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Google Routes no pudo calcular la ruta: ${text}`);
  }

  const payload = await response.json();
  const route = payload.routes?.[0];
  if (!route) return null;

  const durationSeconds = Number(String(route.duration ?? "0s").replace("s", ""));
  return {
    distanceKmOneWay: Number(route.distanceMeters ?? 0) / 1000,
    durationMinutesOneWay: durationSeconds / 60,
    providerPayload: payload,
  };
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

    const body = (await req.json()) as TransportRequest;
    const mapsUrl = body.mapsUrl || body.destination?.mapsUrl || "";
    const addressText = body.addressText || body.destination?.addressText || "";
    let destination = {
      latitude: Number(body.destination?.latitude),
      longitude: Number(body.destination?.longitude),
      addressText,
      zoneName: body.destination?.zoneName,
      mapsUrl,
      resolution: "coordinates" as string,
      providerPayload: null as unknown,
    };

    if (!validCoordinate(destination.latitude, destination.longitude)) {
      if (mapsUrl) {
        const resolved = await resolveMapsUrl(mapsUrl);
        destination = {
          ...destination,
          latitude: resolved.latitude,
          longitude: resolved.longitude,
          mapsUrl: resolved.resolvedUrl,
          resolution: resolved.resolution,
        };
      } else if (addressText) {
        const geocoded = await geocodeAddress(addressText);
        if (!geocoded) {
          return errorResponse("Para calcular transporte pega un link de Google Maps o configura GOOGLE_MAPS_API_KEY para geocodificar direcciones.", 422);
        }
        destination = {
          ...destination,
          latitude: geocoded.latitude,
          longitude: geocoded.longitude,
          addressText: geocoded.formattedAddress || addressText,
          resolution: "geocoded_address",
          providerPayload: geocoded.providerPayload,
        };
      }
    }

    if (!validCoordinate(destination.latitude, destination.longitude)) {
      return errorResponse("No se pudo obtener latitud y longitud del destino. Pega el link compartido de Google Maps o coordenadas.", 422);
    }

    const defaultOrigin = await getDefaultOrigin();
    const origin = body.origin ?? defaultOrigin;
    const rates = await getDefaultRates();
    const loadType = body.loadType ?? "medium";

    let distanceKmOneWay = haversineKm(origin, destination) * 1.25;
    let durationMinutesOneWay = distanceKmOneWay / 25 * 60;
    let provider = destination.resolution === "coordinates" ? "haversine_fallback" : `haversine_fallback_${destination.resolution}`;
    let providerPayload: unknown = destination.providerPayload;

    if (body.useGoogleRoutes !== false && GOOGLE_MAPS_API_KEY) {
      const googleRoute = await getGoogleRoute(origin, destination);
      if (googleRoute) {
        distanceKmOneWay = googleRoute.distanceKmOneWay;
        durationMinutesOneWay = googleRoute.durationMinutesOneWay;
        provider = "google_routes";
        providerPayload = googleRoute.providerPayload;
      }
    }

    const loadSurcharge = loadType === "heavy"
      ? rates.heavyLoadSurcharge
      : loadType === "light"
        ? rates.lightLoadSurcharge
        : rates.mediumLoadSurcharge;

    const rawCost = rates.baseFee
      + distanceKmOneWay * 2 * rates.costPerKmRoundtrip
      + durationMinutesOneWay * 2 * rates.costPerMinute
      + loadSurcharge
      + rates.safetyMargin;

    const suggestedCost = roundToStep(rawCost, rates.roundingStep);

    let eventLocationId: string | null = null;
    if (body.orderId && (destination.addressText || destination.mapsUrl)) {
      const { data: location, error: locationError } = await supabase
        .from("event_locations")
        .insert({
          order_id: body.orderId,
          address_text: destination.addressText || destination.mapsUrl || "Ubicacion compartida por Google Maps",
          maps_url: destination.mapsUrl || null,
          latitude: destination.latitude,
          longitude: destination.longitude,
          zone_name: destination.zoneName ?? null,
        })
        .select("id")
        .single();
      if (locationError) throw locationError;
      eventLocationId = location.id;
    }

    const estimatePayload = {
      order_id: body.orderId ?? null,
      quote_id: body.quoteId ?? null,
      origin_business_location_id: defaultOrigin.id,
      destination_event_location_id: eventLocationId,
      load_type: loadType,
      distance_km_one_way: Number(distanceKmOneWay.toFixed(2)),
      duration_minutes_one_way: Number(durationMinutesOneWay.toFixed(2)),
      suggested_cost: Number(suggestedCost.toFixed(2)),
      provider,
      provider_payload: providerPayload,
    };

    const { data: estimate, error: estimateError } = await supabase
      .from("transport_estimates")
      .insert(estimatePayload)
      .select("*")
      .single();

    if (estimateError) throw estimateError;

    return jsonResponse({
      estimate,
      destination: {
        latitude: destination.latitude,
        longitude: destination.longitude,
        addressText: destination.addressText,
        mapsUrl: destination.mapsUrl,
        resolution: destination.resolution,
      },
      calculation: {
        distanceKmOneWay: Number(distanceKmOneWay.toFixed(2)),
        roundTripKm: Number((distanceKmOneWay * 2).toFixed(2)),
        durationMinutesOneWay: Number(durationMinutesOneWay.toFixed(0)),
        roundTripMinutes: Number((durationMinutesOneWay * 2).toFixed(0)),
        loadType,
        suggestedCost,
        provider,
      },
    });
  } catch (error) {
    return errorResponse(error instanceof Error ? error.message : "Error inesperado.", 500);
  }
});
