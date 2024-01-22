package com.maven;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class MavenAppTest {
    @Test
    public void getMessage() {
        MavenApp app = new MavenApp();
        assertEquals("Default message is valid", app.getMessage(), "Hello from a maven app.");
    }
}
