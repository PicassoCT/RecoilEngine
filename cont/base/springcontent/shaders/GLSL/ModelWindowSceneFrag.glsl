/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
#version 120
uniform sampler2D diffuseTex;
uniform sampler2D extraTex;
uniform vec4 teamColor;
uniform float ambient;
varying vec2 texCoord;
varying vec3 normal;
void main() {
	vec4 diffuse = texture2D(diffuseTex, texCoord);
	vec4 extra = texture2D(extraTex, texCoord);
	if (extra.a < 0.5) discard;
	vec3 albedo = mix(diffuse.rgb, teamColor.rgb, diffuse.a);
	float light = clamp(ambient, 0.0, 1.0) + (1.0-clamp(ambient, 0.0, 1.0)) *
		abs(dot(normalize(normal), normalize(vec3(0.4,0.8,0.5))));
	gl_FragColor = vec4(albedo * max(light, extra.r), 1.0);
}
