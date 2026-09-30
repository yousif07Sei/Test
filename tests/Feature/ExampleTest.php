<?php

namespace Tests\Feature;

use Tests\TestCase;

class ExampleTest extends TestCase
{
    public function test_the_home_page_renders(): void
    {
        $this->withoutVite()->get('/')->assertOk()->assertSee('data-app="demo"', false);
    }

    public function test_the_health_route_answers(): void
    {
        $this->get('/up')->assertOk();
    }
}
