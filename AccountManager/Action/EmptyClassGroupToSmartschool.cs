using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class EmptyClassGroupToSmartschool : IAction
    {
        public string Header => "Lege Klas toevoegen aan Smartschool";

        public string Description => "Je kan geen lege klassen toevoegen aan Smartschool. " +
            "Als de klas niet meer nodig is in Wisa, kan je die manueel verwijderen. Je kan ook wachten tot de Wisa klas " +
            "leerlingen bevat.";

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public bool CanBeApplied => false;

        public async Task Apply(LinkedGroup linkedGroup)
        {

        }
    }
}
