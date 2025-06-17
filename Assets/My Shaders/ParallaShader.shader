// --------------------------------------------------------------------------------------
// File: URP_ParallaxShader.shader
// Author: Javardo Lawrence
// Description: URP-compatible Parallax Mapping shader
// Notes: Written entirely in HLSL, comments and structure provided unlike last time
/* These are the settings I have to emmulate it to how I think it should Look:
Height scale : 0.03
Parallax Steps:7
Shadow softness: 0.5
Ambient light : 0.3

Hopfully it looks ok
*/
// --------------------------------------------------------------------------------------

Shader "Custom/URP_ParallaxShader"
{
    Properties
    {
        // Basic textures for the material
        [MainTexture] _MainTex("Albedo (RGB)", 2D) = "white" {} // The main color texture
        [Normal] _BumpMap("Normal Map", 2D) = "bump" {} // For surface normals and detail
        _HeightMap("Height Map", 2D) = "gray" {} // Essential for parallax, tells us the "depth" of features

        // Parallax specific controls
        _HeightScale("Height Scale", Range(0, 0.1)) = 0.02 // How deep the parallax effect looks
        _ParallaxSteps("Parallax Steps", Range(1, 32)) = 8 // Number of steps for iterative parallax (more steps = better quality, but slower)

        // Inputs for lightmaps - if the scene is baked with lighting
        [NoScaleOffset] _DiffuseLightmap("Diffuse Lightmap", 2D) = "white" {}   // Baked diffuse light
        [NoScaleOffset] _SpecularLightmap("Specular Lightmap", 2D) = "black" {} // Baked specular light
        [NoScaleOffset] _GlossyLightmap("Glossy Lightmap", 2D) = "black" {}     // Baked glossiness/reflection? (Might just use one specular lightmap later, but keeping separate for now)

    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque" // It's a solid, non-transparent object
            "RenderPipeline" = "UniversalPipeline" // Explicitly for URP
            "LightMode" = "UniversalForward" // Using URP's forward rendering pass for lighting
        }

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert // Our vertex shader function
            #pragma fragment frag // Our fragment shader function
            #pragma multi_compile _ LIGHTMAP_ON // Allows Unity to include lightmap code when needed
            #pragma multi_compile_instancing // For GPU instancing optimization (draw many objects efficiently)

            // Include URP's core and lighting functions - super important for getting URP to work!
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // --- Vertex Input Structure ---
            // What Unity gives us for each vertex of the mesh
            struct Attributes
            {
                float4 positionOS : POSITION; // Vertex position in object space
                float2 uv : TEXCOORD0; // UV coordinates for textures
                float2 lightmapUV : TEXCOORD1; // UVs specifically for lightmaps
                float3 normalOS : NORMAL; // Vertex normal in object space
                float4 tangentOS : TANGENT; // Vertex tangent in object space (needed for normal mapping)
            };

            // --- Vertex Output / Fragment Input Structure ---
            // What the vertex shader passes to the fragment shader (interpolated across the triangle)
            struct Varyings
            {
                float4 positionHCS : SV_POSITION; // Clip space position (for drawing on screen)
                float2 uv : TEXCOORD0; // Interpolated UVs
                float2 lightmapUV : TEXCOORD1; // Interpolated lightmap UVs
                float3 viewDirTS : TEXCOORD2; // View direction in Tangent Space (useful for parallax and specular)

                float3 tangentWS : TEXCOORD3; // Tangent in World Space
                float3 bitangentWS : TEXCOORD4; // Bitangent in World Space
                float3 normalWS : TEXCOORD5; // Normal in World Space
                float3 positionWS : TEXCOORD6; // World space position (kept this for accurate viewDirWS calculation in frag)

                UNITY_VERTEX_INPUT_INSTANCE_ID // Macro for instancing data (don't touch unless you know why!)
            };

            // --- Texture Samplers ---
            // Declaring the textures we'll be using
            sampler2D _MainTex, _BumpMap, _HeightMap;
            sampler2D _DiffuseLightmap, _SpecularLightmap, _GlossyLightmap;

            // --- Shader Properties ---
            // Variables exposed in the Inspector, matching the "Properties" block
            float _HeightScale, _ParallaxSteps;
            float4 _MainTex_ST; // Scale and Transform for the main texture (Unity generates this)

            // --------------------------------------
            // Parallax Offset Function
            // This is the core of the parallax mapping. It calculates new UVs
            // based on the height map and view angle, making the surface look deeper.
            // --------------------------------------
            float2 ParallaxOffset(float2 uv, float3 viewDirTS)
            {
                // Determine how much "depth" each step represents
                float layerDepth = 1.0 / _ParallaxSteps;
                float currentDepth = 0; // Starts at the surface

                // Calculate how much UV should shift per step.
                // Multiplying by _HeightScale adjusts the overall depth.
                // Dividing by viewDirTS.z makes it perspective-correct:
                // steeper angles (small viewDirTS.z) mean more offset.
                // Added max(0.001, viewDirTS.z) to avoid division by zero if looking straight on.
                float2 deltaUV = viewDirTS.xy * _HeightScale / (_ParallaxSteps * max(0.001, viewDirTS.z));

                float2 currentUV = uv; // Start with the original UV
                float depth = tex2D(_HeightMap, currentUV).r; // Sample initial height

                // Loop through the steps to find the "true" parallax UV
                // [unroll(32)] tells the compiler to unroll the loop if steps are small (optimizes performance)
                for (int i = 0; i < 32; i++) // Max 32 iterations, but limited by _ParallaxSteps
                {
                    if (i >= _ParallaxSteps) break; // Stop if we've done enough steps
                    if (currentDepth < depth) // If our current "simulated" depth is less than the actual height map depth
                    {
                        currentUV -= deltaUV; // Move the UV back
                        depth = tex2D(_HeightMap, currentUV).r; // Sample new height at the new UV
                        currentDepth += layerDepth; // Increment our simulated depth
                    }
                }
                return currentUV; // Return the final, parallax-corrected UVs
            }

            // --------------------------------------
            // Vertex Shader
            // Prepares data for the fragment shader.
            // --------------------------------------
            Varyings vert(Attributes IN)
            {
                Varyings OUT; // Our output struct
                UNITY_SETUP_INSTANCE_ID(IN); // Needed for instancing

                OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz); // Project vertex to screen space
                OUT.uv = TRANSFORM_TEX(IN.uv, _MainTex); // Apply tiling/offset from material settings
                OUT.lightmapUV = IN.lightmapUV; // Pass lightmap UVs directly

                // Calculate world-space normal, tangent, and bitangent using URP helpers.
                // This builds our TBN matrix (Tangent, Bi-normal, Normal) which is crucial
                // for converting vectors between world and tangent space.
                VertexNormalInputs n = GetVertexNormalInputs(IN.normalOS, IN.tangentOS);
                OUT.tangentWS = n.tangentWS;
                OUT.bitangentWS = n.bitangentWS;
                OUT.normalWS = n.normalWS;

                // Calculate view direction in tangent space:
                // 1. Get world position of the vertex
                float3 positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.positionWS = positionWS; // Store world position (useful for other calculations too, not just fog)
                // 2. Get view direction in world space (from vertex to camera)
                float3 viewDirWS = GetWorldSpaceViewDir(positionWS);
                // 3. Build the TBN matrix from our world-space tangent, bitangent, normal
                float3x3 TBN = float3x3(n.tangentWS, n.bitangentWS, n.normalWS);
                // 4. Transform the world-space view direction into tangent space
                OUT.viewDirTS = mul(TBN, viewDirWS);

                return OUT; // Send everything to the fragment shader!
            }

            // --------------------------------------
            // Fragment Shader
            // Calculates the final color of each pixel.
            // --------------------------------------
            half4 frag(Varyings IN) : SV_Target
            {
                // Rebuild the TBN matrix in the fragment shader.
                // We do this here because the interpolated tangent, bitangent, and normal
                // might not be perfectly orthogonal anymore after interpolation, so we
                // rebuild it for per-pixel accuracy.
                float3x3 TBN = float3x3(IN.tangentWS, IN.bitangentWS, IN.normalWS);

                // Get the parallax-corrected UVs! This is where the magic happens.
                // Normalize the viewDirTS to keep the vector length consistent.
                float2 parallaxUV = ParallaxOffset(IN.uv, normalize(IN.viewDirTS));

                // Sample the normal map with our new parallax UVs and convert to world space.
                // UnpackNormal converts from 0-1 texture values to -1 to 1 normal vectors.
                float3 normalTS = UnpackNormal(tex2D(_BumpMap, parallaxUV));
                float3 normalWS = normalize(mul(TBN, normalTS)); // Transform from Tangent Space to World Space

                // Get the base color (albedo) from the main texture using parallax UVs
                float3 albedo = tex2D(_MainTex, parallaxUV).rgb;

                // --- Lighting Calculation ---
                // Fetch the main directional light's properties using URP's helper.
                Light mainLight = GetMainLight();
                // Calculate NdotL (Normal dot Light direction) - essential for diffuse lighting.
                // saturate ensures it stays between 0 and 1 (no negative light).
                float NdotL = saturate(dot(normalWS, mainLight.direction));

                // Direct diffuse light: The light's color multiplied by NdotL and its shadow attenuation.
                // URP's mainLight.shadowAttenuation automatically handles shadows and their softness.
                // This means I don't need a _ShadowSoftness property anymore - nice!
                float3 directDiffuse = mainLight.color * (NdotL * mainLight.shadowAttenuation);

                // --- Lightmaps / Global Illumination ---
                // Initialize lightmap values to black (or no contribution)
                float3 lightmapDiffuse = 0;
                float3 lightmapSpecular = 0;
                float3 lightmapGlossy = 0;

                #ifdef LIGHTMAP_ON // If lightmaps are enabled (set on the object in Unity)
                    lightmapDiffuse = tex2D(_DiffuseLightmap, IN.lightmapUV).rgb; // Sample diffuse lightmap
                    lightmapSpecular = tex2D(_SpecularLightmap, IN.lightmapUV).rgb; // Sample specular lightmap
                    lightmapGlossy = tex2D(_GlossyLightmap, IN.lightmapUV).rgb; // Sample glossy lightmap
                #else
                    // If no lightmaps are used, use Spherical Harmonics (SH) for ambient light.
                    // This is URP's way of getting general ambient/indirect lighting from the skybox
                    // or environment probes. This should help prevent those completely black areas!
                    lightmapDiffuse = SampleSH(normalWS);
                #endif

                // --- Combining all lighting components ---
                // Final diffuse color: Albedo multiplied by the sum of direct light and lightmap/SH ambient.
                float3 diffuse = albedo * (directDiffuse + lightmapDiffuse);

                // Specular and Glossy: For now, I'm taking these directly from lightmaps if available.
                // This might need more work for a full PBR model, but it's a start.
                float3 specular = lightmapSpecular;
                float3 glossy = lightmapGlossy;

                // Basic Phong-like specular for real-time lights (if not fully relying on lightmaps).
                // I need the view direction again in world space.
                float3 viewDirWS = GetWorldSpaceViewDir(IN.positionWS);
                // Calculate the Half-Vector (midpoint between light and view directions)
                float3 halfDir = normalize(mainLight.direction + viewDirWS);
                // NdotH is Normal dot Half-Vector, used for specular highlights
                float NdotH = saturate(dot(normalWS, halfDir));
                float shininess = 32.0; // Hardcoded shininess, maybe make this a property later?
                // Add direct specular light, also affected by shadows
                specular += mainLight.color * pow(NdotH, shininess) * mainLight.shadowAttenuation;


                // Final color is the sum of diffuse, specular, and glossy components.
                float3 finalColor = diffuse + specular + glossy;

                // Fog lines were removed here. This material won't be affected by global fog.

                return half4(finalColor, 1); // Output the final color (with alpha of 1, meaning opaque)
            }
            ENDHLSL
        }
    }
}