"use client"
import { useQuery } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useTRPC } from "@/utils/trpc";
import Link from "next/link";
import { Button } from "@lumen-health/ui/components/button";

export default function Home() {
  const trpc = useTRPC();
  const healthCheck = useQuery(trpc.healthCheck.queryOptions());
  const [version, setVersion] = useState<string | null>(null);

  useEffect(() => {
    fetch(`${window.location.protocol}//${window.location.hostname}:3000/version`)
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d && setVersion(d.version))
      .catch(() => {});
  }, []);

  return (
    <div className="container mx-auto max-w-3xl px-4 py-12">
      <div className="mb-10">
        <p className="text-sm font-medium text-primary">Lumen Health</p>
        <h1 className="mt-1 text-4xl font-bold tracking-tight">Care coordination, simplified</h1>
        <p className="mt-3 text-lg text-muted-foreground">
          Track care tasks across your team — powered by the Lumen Health platform.
        </p>
        <div className="mt-6">
          <Link href="/tasks">
            <Button size="lg">Open Care Tasks</Button>
          </Link>
        </div>
      </div>
      <div className="grid gap-6 sm:grid-cols-2">
        <section className="rounded-lg border p-4">
          <h2 className="mb-2 font-medium">API Status</h2>
            <div className="flex items-center gap-2">
              <div
                className={`h-2 w-2 rounded-full ${healthCheck.data ? "bg-green-500" : "bg-red-500"}`}
              />
              <span className="text-sm text-muted-foreground">
                {healthCheck.isLoading
                  ? "Checking..."
                  : healthCheck.data
                    ? "Connected"
                    : "Disconnected"}
              </span>
            </div>
        </section>
        <section className="rounded-lg border p-4">
          <h2 className="mb-2 font-medium">Deployment</h2>
          <span className="text-sm text-muted-foreground">
            version: {version ?? "…"}
          </span>
        </section>
      </div>
    </div>
  );
}
