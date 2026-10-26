import Foundation

struct ScriptExample: Identifiable {
    var id: String { name }
    let name: String
    let title: String
    let detail: String
    let symbol: String
    let code: String
}

enum Starter {
    static let welcome = #"""
# Welcome to PyPhone 2.
# Your changes save automatically.

name = input("What's your name? ")
print("Hello,", name + "!")
print("You're running Python on your iPhone.")
"""#

    static let code = #"""
from ui import label, entry, button

# Open the Window tab to see your interface.
name = entry("Your name")
greeting = label("Ready when you are.")
count = label("Taps: 0")
taps = 0

def hello():
    greeting.set("Hello, " + (name.get() or "world") + "!")

def tap():
    global taps
    taps += 1
    count.set("Taps: " + str(taps))

button("Say hello", hello)
button("Tap me", tap)
print("Your interface is ready in Window.")
"""#

    static let all: [ScriptExample] = [
        ScriptExample(name: "hello", title: "Hello, Python", detail: "Print and input", symbol: "hand.wave", code: welcome),
        ScriptExample(name: "number_game", title: "Guess the number", detail: "Loops, input, and booleans", symbol: "dice", code: #"""
import random

secret = random.randint(1, 20)
playing = True
attempts = 0
print("I'm thinking of a number from 1 to 20.")

while playing:
    answer = input("Your guess (or quit): ")
    if answer.lower() == "quit":
        playing = False
    elif not answer.isdigit():
        print("Enter a whole number.")
    else:
        guess = int(answer)
        attempts += 1
        if guess < secret:
            print("Too low!")
        elif guess > secret:
            print("Too high!")
        else:
            print("You got it in", attempts, "guesses!")
            playing = False
"""#),
        ScriptExample(name: "my_window", title: "Build a window", detail: "Buttons, labels, and text fields", symbol: "rectangle.3.group", code: code),
        ScriptExample(name: "arrays", title: "Explore arrays", detail: "NumPy filtering and calculations", symbol: "number.square", code: #"""
import numpy as np

numbers = np.array([5, 15, 25, 35, 45])
print("All numbers:", numbers)
print("Between 10 and 40:", numbers[(numbers > 10) & (numbers < 40)])
print("Above 20:", np.sum(numbers > 20))
print("Average:", np.mean(numbers))
"""#)
    ]
}
