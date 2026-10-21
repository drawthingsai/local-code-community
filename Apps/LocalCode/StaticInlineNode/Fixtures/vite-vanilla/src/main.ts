import "./style.css";

type FixtureResult = {
  runtime: string;
  value: number;
};

const result: FixtureResult = {
  runtime: "NodeMobile",
  value: 6 * 7,
};

const app = document.querySelector<HTMLElement>("#app");
if (app) {
  app.textContent = `${result.runtime}: ${result.value}`;
}
