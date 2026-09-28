/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */
#version 120
uniform int farDepth;
uniform vec3 background;
void main() {
	gl_FragColor = vec4(background, 1.0);
	gl_FragDepth = (farDepth != 0) ? 1.0 : gl_FragCoord.z;
}
