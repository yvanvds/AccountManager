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

            // add 5 charactes (uppercase and lowercase mixed, no i, I, l, L, o, O)
            for (int charPos = 1; charPos < 6; charPos++)
            {
                password[charPos] = CHARACTERS[random.Next(CHARACTERS.Length)];

                // make sure that no 3 sequential chars are the same
                bool identical = charPos > 2 && password[charPos] == password[charPos - 1]
                    && password[charPos - 1] == password[charPos - 2];

                if (identical) charPos--;
            }

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

        static readonly string CAPITALS = "ABCDEFGHJKMNPQRSTUVWXYZ";
        static readonly string CHARACTERS = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ";

        
    }
}
