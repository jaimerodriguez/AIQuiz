

I want to create an iPadOS and iOS application called AIQuiz that tests my knowledge on specific topics. 

THe knowledge for each quiz will be stored in a simple json file with the following sample or template format:

{ 
    quiz : { 
        'name': '<quiz name will be here>' , 
        'score' :  { 
                best: 100, 
                average: 50 
        }, 
        'cards' : [ 
                { 
                    'prompt' : 'has the text that is the front of the card. Assume it is one or two lines (20 to 200 characters)' ,  
                    'long-answer' : 'has a multi-line answer. this can be longer, 20 to 400 characters' ,
                    'short-answer' : 'an optioanal, shorters, sharp version of the answer',  
                    'hint' : 'an optional multi-line hint that can be displayed (based on an action) with the prompt' 
                },  
                { 
                    'prompt' : 'Amdahl's law' 
                    'long-answer' :  'if you parallelize or accelerate part of a system, your overall speedup is bounded by the part you _didn't_ speed up. ' 
                    'short-answer' :  'the slowest unaccelerated part caps your total speedup', 
                    'hint' :  
                }
        ]
    }
}

There are multiple formats to study and be quized: 

Study format #1: Automated Voice Reading. 
- The app will read out loud in a single screen the prompt, and then the short and long-answer for the card. 
- There should be a button to repeat the card if needed. 
- There should be an option where in a quiz, you repeat each card n times ( configurable in settings) and then read the next card. 
- The app will move to the next card after it has read the current one. 


Study format #2: User reads the cards:  
- The app will show one card with the prompt, the short, and long answer for the card.  
- User has to explicitly touch a button to move to the next card. 


Quiz format #1: 
- The user will see the prompt for the card. 
-  When they see the prompt, they will be able to answer via voice, this voice input will be captured and transcribed. 
- If the user does not want to answer via voice, they press a button and  flip the card and see the answer. 


The app will read the json file for each quiz by reading it or importing it from as many places as possible.  
For example, we can prompt for the quiz, and use the Files functionality in iOS to read it from files.  It should also be able to connect to apps like onedrive, dropbox, etc.  The most storage providers in iOS. 

When a Quiz is read, its name and its file location will be saved in the app so the user can re-read it in a different session. 



