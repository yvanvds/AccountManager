using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi
{
    public static class Password
    {
        public static string Create()
        {
            char[] password = new char[8];

            // start with a capital
            password[0] = CAPITALS[random.Next(CAPITALS.Length)];
            password[1] = VOWELS[random.Next(VOWELS.Length)];
            password[2] = CONSONANTS[random.Next(CONSONANTS.Length)];
            password[3] = VOWELS[random.Next(VOWELS.Length)];
            password[4] = CONSONANTS[random.Next(CONSONANTS.Length)];
            password[5] = VOWELS[random.Next(VOWELS.Length)];

            // add a number in range 2 to 9 (zero and one are not included because they are easily confused with o and i)
            password[6] = (char)(48 + random.Next(2, 10));

            // add a symbol
            switch(random.Next(3))
            {
                case 0: password[7] = '!'; break;
                case 1: password[7] = '?'; break;
                case 2: password[7] = '*'; break;
            }

            return string.Join(null, password);
        }

        static private Random random = new Random();

        static readonly string CAPITALS = "BCDFGHJKMNPQRSTVWXZ";
        static readonly string VOWELS = "aeiouy";
        static readonly string CONSONANTS = "bcdfghjkmnpqrstvwxz";
    }
}
