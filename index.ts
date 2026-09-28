import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

function generateOtp(): string {
  const max = Math.floor(0x100000000 / 900000) * 900000;
  const random = new Uint32Array(1);

  do {
    crypto.getRandomValues(random);
  } while (random[0] >= max);

  return String(100000 + (random[0] % 900000));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return response({ error: "Method not allowed" }, 405);
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    const otpFromEmail = Deno.env.get("OTP_FROM_EMAIL");

    if (!supabaseUrl || !supabaseAnonKey) {
      return response({ error: "Supabase configuration is missing." }, 500);
    }

    if (!resendApiKey || !otpFromEmail) {
      return response({ error: "Email service is not configured." }, 500);
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return response({ error: "Authorization required." }, 401);
    }

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: authHeader,
        },
      },
    });

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError || !user) {
      return response({ error: "Invalid or expired session." }, 401);
    }

    if (!user.email) {
      return response({ error: "Your account has no email address." }, 400);
    }

    if (!user.email_confirmed_at) {
      return response(
        { error: "Please verify your email address before transferring money." },
        403,
      );
    }

    const body = await req.json();
    const transferRequestId = body?.transfer_request_id;

    if (!transferRequestId) {
      return response({ error: "transfer_request_id is required." }, 400);
    }

    const otp = generateOtp();

    // IMPORTANT: this matches the Step 5 database function actually deployed:
    // create_transfer_otp_challenge(uuid, text)
    const { data: otpResult, error: otpError } = await supabase.rpc(
      "create_transfer_otp_challenge",
      {
        p_transfer_request_id: transferRequestId,
        p_code: otp,
      },
    );

    if (otpError) {
      console.error("OTP challenge creation error:", otpError);
      return response(
        { error: "Unable to create the verification code." },
        400,
      );
    }

    if (!otpResult?.success || !otpResult?.challenge_id) {
      return response(
        { error: otpResult?.message || "Verification challenge was not created." },
        400,
      );
    }

    const emailResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: `NEXUS Bank <${otpFromEmail}>`,
        to: [user.email],
        subject: "NEXUS Bank Transfer Verification Code",
        html: `
          <div style="font-family:Arial,sans-serif;max-width:600px;margin:auto;padding:24px;color:#111827">
            <h2 style="margin-bottom:8px">NEXUS Bank</h2>
            <p>A verification code was requested for a money transfer on your NEXUS account.</p>
            <div style="font-size:32px;font-weight:bold;letter-spacing:8px;padding:20px 0">
              ${otp}
            </div>
            <p>This code expires in 10 minutes.</p>
            <p>If you did not request this transfer, do not enter the code and contact NEXUS Customer Care.</p>
          </div>
        `,
      }),
    });

    if (!emailResponse.ok) {
      console.error("Email sending failed:", await emailResponse.text());

      // The challenge is server-side, so cancel the transfer request when
      // delivery fails. This prevents an undelivered OTP from remaining usable.
      await supabase.rpc("cancel_transfer_request", {
        p_transfer_request_id: transferRequestId,
      });

      return response(
        { error: "The verification email could not be sent." },
        502,
      );
    }

    return response({
      success: true,
      message: "Verification code sent successfully.",
      challenge_id: otpResult.challenge_id,
      expires_at: otpResult.expires_at,
    });
  } catch (error) {
    console.error("Unexpected error:", error);
    return response(
      { error: "An unexpected server error occurred." },
      500,
    );
  }
});
