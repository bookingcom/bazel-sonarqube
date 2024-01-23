package com.maven;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class MavenApp {
    private final String message;
    private static final Logger logger = LoggerFactory.getLogger(MavenApp.class);

    public MavenApp() {
        logger.info("MavenApp starting");
        this.message = "Hello from a maven app.";
    }

    public String getMessage() {
        return this.message;
    }
}
