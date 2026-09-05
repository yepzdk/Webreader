pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // Repositories are declared here and nowhere else, so a subproject cannot quietly add a
    // source of artifacts that CI has not seen.
    repositoriesMode = RepositoriesMode.FAIL_ON_PROJECT_REPOS
    repositories {
        google()
        mavenCentral()
    }
}

// Deliberately not "WebReader": the Gradle build lives in `android/` inside a Swift package,
// and the root project name is what the APK and the build directory are named after.
rootProject.name = "WebReader"

include(":app")
