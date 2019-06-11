using System;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class DoNotImportClassGroupFromSmartschool : GroupAction
    {

        public override Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public DoNotImportClassGroupFromSmartschool() : base(
            "Klas Negeren",
            "Importeer deze klas niet uit Smartschool. Doe dit wanneer de klas moet bestaan in smartschool maar " +
            "niet gelinkt is aan een klas in Wisa en Active Directory.",
            true
            )
        {
        }
    }
}
