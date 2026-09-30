<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="csrf-token" content="{{ csrf_token() }}">
    <title>{{ config('app.name') }}</title>
    @vite(['resources/css/app.css', 'resources/js/app.js'])
</head>
<body class="min-h-screen bg-slate-50 text-slate-800 flex items-center justify-center">
    <main class="text-center p-8">
        <h1 class="text-3xl font-bold">{{ config('app.name') }}</h1>
        <p class="mt-2 text-slate-500" data-app="demo">A placeholder app for the CI/CD pipeline.</p>
        {{-- BUILD is written by scripts/build-release.sh: "source   <sha>" first. --}}
        <p class="mt-6 text-sm text-slate-400">{{ is_file(base_path('BUILD')) ? trim(strtok(file_get_contents(base_path('BUILD')), "\n")) : 'local build' }}</p>
        <p id="greeting" class="mt-2 text-sm"></p>
    </main>
</body>
</html>
