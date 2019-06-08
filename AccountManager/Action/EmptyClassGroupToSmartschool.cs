using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class EmptyClassGroupToSmartschool : GroupAction
    {
        public override Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public EmptyClassGroupToSmartschool() : base(
            "Lege Klas toevoegen aan Smartschool",
            "Als de klas niet meer nodig is in Wisa, kan je die manueel verwijderen. Je kan ook wachten tot de Wisa klas " +
            "leerlingen bevat.",
            false)
        {

        }
    }
}
